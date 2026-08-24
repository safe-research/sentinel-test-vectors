# shellcheck shell=bash
#
# lib/common.sh — helpers shared by bin/check-specs.sh and bin/run-tests.sh.
#
# Sourced, never executed. The caller must set ROOT to the repository root
# before sourcing, and is expected to have run `set -euo pipefail`.

# die EXIT_CODE MESSAGE...
die() {
  local code=$1
  shift
  echo "$*" >&2
  exit "$code"
}

# parse_spec_args [ARG...]
#
# Splits a command line into OPTIONS and SPECS. Every argument beginning with a
# "-", up to an optional "--" terminator, is appended to OPTIONS verbatim; the
# rest are spec selectors and are resolved into SPECS.
parse_spec_args() {
  local -a operands=()
  local end_of_options=false arg

  # OPTIONS and SPECS are the outputs of this function, read by the sourcing
  # script.
  # shellcheck disable=SC2034
  OPTIONS=()

  for arg in "$@"; do
    if ! $end_of_options; then
      case $arg in
        --) end_of_options=true; continue ;;
        -*) OPTIONS+=("$arg"); continue ;;
      esac
    fi
    operands+=("$arg")
  done

  resolve_specs "${operands[@]}"
}

# resolve_specs [OPERAND...]
#
# Populates the SPECS array with repository-relative spec paths, sorted and
# deduplicated.
#
# Operands are spec selectors, not arbitrary file paths:
#
#   (none), all           the whole corpus
#   <group>               every case in that group
#   <group>/<case>.json   one case
#
# A leading "specs/" is accepted and stripped on both forms, so a path produced
# by shell tab-completion works exactly as typed. An operand that matches
# nothing produces an error.
resolve_specs() {
  local -a operands=("$@")
  (( ${#operands[@]} )) || operands=(all)

  local -a found=() matches=()
  local operand selector pattern

  for operand in "${operands[@]}"; do
    selector=${operand#specs/}
    selector=${selector%/}

    case $selector in
      all)
        pattern="$ROOT/specs/*/*.json"
        ;;
      */*.json)
        pattern="$ROOT/specs/$selector"
        ;;
      *)
        pattern="$ROOT/specs/$selector/*.json"
        ;;
    esac

    mapfile -t matches < \
      <(find "$ROOT/specs" -mindepth 2 -maxdepth 2 -type f -path "$pattern")
    if (( ${#matches[@]} == 0 )); then
      die 2 "no specs match \"$operand\""
    fi

    found+=("${matches[@]#"$ROOT"/}")
  done

  # SPECS is the output of this function, read by the sourcing script.
  # shellcheck disable=SC2034
  mapfile -t SPECS < \
    <(printf '%s\n' "${found[@]}" | LC_ALL=C sort -u)
}
