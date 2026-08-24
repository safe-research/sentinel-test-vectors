#!/usr/bin/env bash
#
# Validate the test vector corpus. Every spec must parse as a single JSON value,
# satisfy the schema in lib/spec.jq, and already be in the canonical form that
# lib/canonical.jq produces.
#
# Needs no network and no sentinel engine.

set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

usage() {
  cat <<USAGE
Usage: $0 [--fix] [specs...]

Options:
  --fix       Rewrite specs into canonical form instead of reporting formatting
              violations. Schema errors are reported and never auto-fixed.
  -h, --help  Show this message.

Operands:
  specs       "all" (the default), a <group>, or a <group>/<case>.json.
              A leading "specs/" is accepted.
USAGE
}

parse_spec_args "$@"

fix=false
for option in "${OPTIONS[@]}"; do
  case $option in
    --fix) fix=true ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown option \"$option\"" >&2; usage >&2; exit 2 ;;
  esac
done

# jq writes to a temporary file beside the original: redirecting straight onto
# the input would truncate it before jq had finished reading.
scratch=
# Invoked via the EXIT trap below, which shellcheck cannot see.
# shellcheck disable=SC2317
cleanup() {
  [[ -n $scratch ]] && rm -f -- "$scratch"
  # Must not fall out of the trap on a non-zero status: under `set -e` that
  # would overwrite the script's real exit code with this test's result.
  return 0
}
trap cleanup EXIT

report() {
  # jq's own diagnostics can span lines; a spec's errors are one per line.
  printf '%s: %s\n' "$1" "${2//$'\n'/ }" >&2
}

status=0
invalid=0
reformatted=0

for spec in "${SPECS[@]}"; do
  file="$ROOT/$spec"

  if ! parse_error=$(jq empty -- "$file" 2>&1); then
    report "$spec" "invalid JSON: $parse_error"
    status=1
    (( ++invalid ))
    continue
  fi

  # A spec is exactly one vector. Two concatenated objects parse fine but would
  # make every later check report twice.
  values=$(jq -s 'length' -- "$file")
  if (( values != 1 )); then
    report "$spec" "expected exactly one JSON value, found $values"
    status=1
    (( ++invalid ))
    continue
  fi

  if ! violations=$(jq -r -f "$ROOT/lib/spec.jq" -- "$file" 2>&1); then
    report "$spec" "validator failed: $violations"
    status=1
    (( ++invalid ))
    continue
  fi

  if [[ -n $violations ]]; then
    while IFS= read -r violation; do
      report "$spec" "$violation"
    done <<<"$violations"
    status=1
    (( ++invalid ))
    # Stop here deliberately. lib/canonical.jq drops properties it does not
    # know, so neither the formatting check nor --fix has any business touching
    # a file whose shape we just rejected.
    continue
  fi

  if ! canonical=$(jq --indent 2 -f "$ROOT/lib/canonical.jq" -- "$file" 2>&1); then
    report "$spec" "canonicalisation failed: $canonical"
    status=1
    (( ++invalid ))
    continue
  fi

  # Command substitution strips trailing newlines, so append a sentinel to make
  # the presence of the final newline observable on both sides.
  expected="$canonical"$'\nx'
  actual="$(cat -- "$file"; printf x)"

  if [[ $expected == "$actual" ]]; then
    printf '%s: OK\n' "$spec"
    continue
  fi

  if ! $fix; then
    report "$spec" "not canonically formatted (run $0 --fix)"
    status=1
    (( ++invalid ))
    continue
  fi

  scratch="$file.canonical.$$"
  printf '%s\n' "$canonical" >"$scratch"
  mv -f -- "$scratch" "$file"
  scratch=
  printf '%s: reformatted\n' "$spec"
  (( ++reformatted ))
done

total=${#SPECS[@]}
if (( status == 0 )); then
  if (( reformatted )); then
    printf '%d spec(s) checked, %d reformatted\n' "$total" "$reformatted"
  else
    printf '%d spec(s) checked, all valid\n' "$total"
  fi
else
  printf '%d of %d spec(s) invalid\n' "$invalid" "$total" >&2
fi

exit "$status"
