#!/usr/bin/env bash
#
# Replay the test vector corpus against a running sentinel engine and report a
# per-group scorecard.
#
# A vector passes when the engine returns the verdict the vector expects, and
# for an insecure verdict the same Charter rule. An engine that abstains has
# declined to answer rather than answered wrongly, so that counts as a skip —
# but a skip is not a pass, and only a clean sweep exits 0.

set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

usage() {
  cat <<USAGE
Usage: $0 [--parallel=N] [--sentinel-engine-url=URL] [--sentinel-timeout=SECONDS] [specs...]

Options:
  --parallel=N                Run up to N specs concurrently. Positive integer.
                              Environment: PARALLEL. Default: 1.
  --sentinel-engine-url=URL   Engine base URL; /v1/security-check is appended.
                              Environment: SENTINEL_ENGINE_URL.
                              Default: http://localhost:5473.
  --sentinel-timeout=SECONDS  Per-request budget in seconds. Positive integer.
                              Environment: SENTINEL_TIMEOUT. Default: 30.
  -h, --help                  Show this message.

Operands:
  specs                       "all" (the default), a <group>, or a
                              <group>/<case>.json. A leading "specs/" is
                              accepted.
USAGE
}

parse_spec_args "$@"

parallel="${PARALLEL:-1}"
engine_url="${SENTINEL_ENGINE_URL:-http://localhost:5473}"
timeout="${SENTINEL_TIMEOUT:-30}"

for option in "${OPTIONS[@]}"; do
  case $option in
    -h | --help)
      usage
      exit 0
      ;;
    --parallel=*)
      parallel="${option#*=}"
      ;;
    --sentinel-engine-url=*)
      engine_url=${option#*=}
      ;;
    --sentinel-timeout=*)
      timeout=${option#*=}
      ;;
    --parallel | --sentinel-engine-url | --sentinel-timeout)
      die 2 "$option: expected $option=VALUE"
      ;;
    *)
      echo "unknown option \"$option\"" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ $parallel =~ ^[1-9][0-9]*$ ]] ||
  die 2 "--parallel: expected a positive integer, got \"$parallel\""
[[ $timeout =~ ^[1-9][0-9]*$ ]] ||
  die 2 "--sentinel-timeout: expected a positive integer, got \"$timeout\""
[[ $engine_url =~ ^https?://[^[:space:]]+$ ]] ||
  die 2 "--sentinel-engine-url: expected an http(s) base URL, got \"$engine_url\""

(( parallel == 1 )) ||
  die 2 "--parallel: parallelism is not implemented yet, only 1 is supported"

# One outcome is one line, and an engine that returns a megabyte of HTML should
# not flood the report with it.
oneline() {
  local text=${1//$'\n'/ }
  if (( ${#text} > 120 )); then
    printf '%s...' "${text:0:117}"
  else
    printf '%s' "$text"
  fi
}

declare -A group_total=() group_pass=() group_fail=() group_skip=()
declare -a groups=()
total=0 passed=0 failed=0 skipped=0

for spec in "${SPECS[@]}"; do
  file="$ROOT/$spec"

  group=${spec#specs/}
  group=${group%%/*}
  if [[ -z ${group_total[$group]:-} ]]; then
    groups+=("$group")
    group_total[$group]=0 group_pass[$group]=0
    group_fail[$group]=0 group_skip[$group]=0
  fi

  expected=$(jq -r '.verdict' -- "$file")
  expected_rule=$(jq -r '.rule // ""' -- "$file")

  outcome=FAIL
  detail=

  if ! response=$(curl -sS -X POST \
    -H 'content-type: application/json' \
    -H "x-request-timeout: $((timeout * 1000))" \
    --max-time "$timeout" \
    -w '\n%{http_code}' \
    --data-binary "$(jq -c '{transaction}' -- "$file")" \
    -- "${engine_url%/}/v1/security-check" 2>&1); then
    # curl writes the -w template even when it fails, so the captured text ends
    # in a bare "000" status. Keep only curl's own first line.
    detail="request failed: $(oneline "${response%%$'\n'*}")"
  else
    code=${response##*$'\n'}
    payload=${response%$'\n'*}

    if [[ $code != 200 ]]; then
      detail="HTTP $code"
    elif ! jq -es 'length == 1 and (.[0] | type) == "object"' \
      <<<"$payload" >/dev/null 2>&1; then
      detail="response is not a JSON object: $(oneline "$payload")"
    else
      actual=$(jq -r '.verdict // ""' <<<"$payload")
      actual_rule=$(jq -r '.rule // ""' <<<"$payload")

      case $actual in
        abstain)
          outcome=SKIP
          detail="engine abstained"
          ;;
        secure | insecure)
          if [[ $actual != "$expected" ]]; then
            if [[ $actual == insecure && -n $actual_rule ]]; then
              detail="expected $expected, got insecure ($actual_rule)"
            else
              detail="expected $expected, got $actual"
            fi
          elif [[ $actual == secure ]]; then
            outcome=PASS
          elif [[ -z $actual_rule ]]; then
            detail="expected insecure ($expected_rule), got insecure with no rule"
          elif [[ $actual_rule != "$expected_rule" ]]; then
            detail="expected insecure ($expected_rule), got insecure ($actual_rule)"
          else
            outcome=PASS
          fi
          ;;
        *)
          detail="unrecognised verdict: $(oneline "$payload")"
          ;;
      esac
    fi
  fi

  (( ++total ))
  (( ++group_total[$group] ))
  case $outcome in
    PASS)
      (( ++passed ))
      (( ++group_pass[$group] ))
      printf 'PASS %s\n' "$spec" ;;
    SKIP)
      (( ++skipped ))
      (( ++group_skip[$group] ))
      printf 'SKIP %s: %s\n' "$spec" "$detail" ;;
    FAIL)
      (( ++failed ))
      (( ++group_fail[$group] ))
      printf 'FAIL %s: %s\n' "$spec" "$detail" ;;
  esac
done

# The useful question about an engine is usually which areas it covers, not
# whether it is perfect, so the totals are broken down per group. Percentages
# are shares of each group's own count, so a small group is not drowned by a
# large one.
width=5
for group in "${groups[@]}" TOTAL; do
  (( ${#group} > width )) && width=${#group}
done

echo
header=$(printf '%-*s %5s %8s %8s %8s' "$width" GROUP TESTS PASSED FAILED SKIPPED)
printf '%s\n' "$header"

percent() { # round(numerator * 100 / denominator) in integer arithmetic.
  (( $2 == 0 )) && { printf 0; return; }
  printf '%d' $(( ($1 * 100 + $2 / 2) / $2 ))
}

row() { # name total pass fail skip
  printf '%-*s %5d %7s%% %7s%% %7s%%\n' "$width" "$1" "$2" \
    "$(percent "$3" "$2")" "$(percent "$4" "$2")" "$(percent "$5" "$2")"
}

for group in "${groups[@]}"; do
  row "$group" "${group_total[$group]}" "${group_pass[$group]}" \
    "${group_fail[$group]}" "${group_skip[$group]}"
done

printf '%*s\n' "${#header}" '' | tr ' ' -
row TOTAL "$total" "$passed" "$failed" "$skipped"

# A skip is not a pass: an engine that cannot decide a vector is an engine that
# does not handle it. Only 100% passed exits 0.
(( failed == 0 && skipped == 0 ))
