#!/usr/bin/env bash
#
# bin/craft-spec.sh — craft a spec from a real, already-executed Safe transaction.
#
# Given a chain, a Safe address and a SafeTxHash (the EIP-712 hash of the
# SafeTx struct, not an on-chain transaction hash), this looks up the Safe's
# ExecutionSuccess event for that hash, pulls the enclosing transaction's
# calldata, decodes the execTransaction() arguments, recovers the nonce, and
# writes a new spec into specs/<category>/.
#
# The verdict and, when insecure, the rule it cites are supplied by the
# caller: nothing about them can be derived from the chain. The spec is
# written and then run through bin/check-specs.sh --fix, the same tool a
# human author would use, so the file that lands on disk is schema-valid and
# canonically formatted, or this script fails loudly and cleans up after
# itself.
#
# Needs Foundry's `cast` on PATH for every bit of chain interaction and ABI
# decoding, plus this repository's usual jq.

set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

# keccak256("ExecutionSuccess(bytes32,uint256)"), the event GnosisSafe/Safe{Wallet}
# emits at the end of a successful execTransaction(). Fixed regardless of Safe
# version -- what *does* differ by version is whether txHash is `indexed`
# (Safe v1.4+) or plain (v1.1-v1.3), which changes whether it shows up as
# topics[1] or inside `data`. See find_execution_log, which handles both
# without needing to know the version.
EXECUTION_SUCCESS_TOPIC=0x442e715f626346e8c54381002da614f62bee8d27386535b2521ec8540898556e
EXEC_TRANSACTION_SIG='execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)'
EXEC_TRANSACTION_SELECTOR=0x6a761202

usage() {
  cat <<USAGE
Usage: $0 [OPTIONS]

Required:
  --chain-id ID          Decimal chain ID.
  --safe ADDRESS         Safe address.
  --safe-tx-hash HASH    SafeTxHash (the SafeTx struct hash, not an on-chain tx hash).
  --verdict V            "secure" or "insecure".
  --category NAME        specs/<category> to write into.

Conditionally required:
  --rule ID              Charter rule citation, e.g. "R-4.3". Required when
                          --verdict is "insecure", forbidden otherwise.

Optional:
  --note TEXT            Prose explaining the rationale.
  --name NAME            Filename (without .json) instead of the default.
  --force                Overwrite an existing spec.
  --rpc-url URL          RPC endpoint instead of looking one up in RPC_URLS.
  --from-block N         Lower bound of the log search (default: 0).
  --to-block N           Upper bound of the log search (default: chain head).
  --scan-window N        Max block range per eth_getLogs call (default: 5000).
  -h, --help             Show this message.

Environment:
  RPC_URLS   JSON object mapping decimal chain IDs to RPC URLs, e.g.
             {"11155111":"https://...","100":"https://..."}. Consulted when
             --rpc-url is not given.
USAGE
}

chain_id='' safe='' safe_tx_hash='' verdict='' category='' rule='' note='' name=''
force=false rpc_url='' from_block=0 to_block='' scan_window=5000

while [[ $# -gt 0 ]]; do
  case $1 in
    --chain-id) chain_id=$2; shift 2 ;;
    --safe) safe=$2; shift 2 ;;
    --safe-tx-hash) safe_tx_hash=$2; shift 2 ;;
    --verdict) verdict=$2; shift 2 ;;
    --category) category=$2; shift 2 ;;
    --rule) rule=$2; shift 2 ;;
    --note) note=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    --force) force=true; shift ;;
    --rpc-url) rpc_url=$2; shift 2 ;;
    --from-block) from_block=$2; shift 2 ;;
    --to-block) to_block=$2; shift 2 ;;
    --scan-window) scan_window=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die 2 "unknown option \"$1\"" ;;
  esac
done

for required in chain_id safe safe_tx_hash verdict category; do
  [[ -n ${!required} ]] || { usage >&2; die 2 "--${required//_/-} is required"; }
done

case $verdict in
  secure) [[ -z $rule ]] || die 2 '--rule must be omitted when --verdict is "secure"' ;;
  insecure)
    [[ -n $rule ]] || die 2 '--rule is required when --verdict is "insecure"'
    [[ $rule =~ ^R-[0-9]+\.[0-9]+$ ]] \
      || die 2 "--rule: not a Charter rule citation such as \"R-4.3\", got \"$rule\""
    ;;
  *) die 2 '--verdict must be "secure" or "insecure"' ;;
esac

[[ $safe =~ ^0x[0-9a-fA-F]{40}$ ]] || die 2 "--safe: not an address, got \"$safe\""
[[ $safe_tx_hash =~ ^0x[0-9a-fA-F]{64}$ ]] \
  || die 2 "--safe-tx-hash: not a 32-byte hash, got \"$safe_tx_hash\""
safe_tx_hash=${safe_tx_hash,,}
safe=$(cast to-checksum "$safe")

if [[ -z $rpc_url ]]; then
  [[ -n ${RPC_URLS:-} ]] || die 1 "no --rpc-url given and RPC_URLS is not set. RPC_URLS must be a JSON object mapping decimal chain IDs to RPC URLs, e.g. {\"11155111\":\"https://...\",\"100\":\"https://...\"}"
  rpc_url=$(jq -r --arg id "$chain_id" '.[$id] // empty' <<<"$RPC_URLS") \
    || die 1 "RPC_URLS is not valid JSON"
  [[ -n $rpc_url ]] || die 1 "RPC_URLS has no entry for chain ID $chain_id"
fi
export ETH_RPC_URL=$rpc_url

[[ -n $to_block ]] || to_block=$(cast block-number)

# find_execution_log -> prints the matching ExecutionSuccess log JSON on
# stdout, exit 1 if nothing in [from_block, to_block] matches.
#
# A plain fromBlock=0/toBlock=latest call is what most providers refuse:
# public RPC endpoints commonly cap the block range of a single eth_getLogs
# call, regardless of how narrow the address/topic filter is (one observed
# in the wild allows all of ten blocks). Scanning backwards in bounded
# windows keeps each call within that cap and finds recent transactions (the
# common case) in the first few requests.
#
# The SafeTxHash is never passed as a second topic: it is only `indexed` on
# Safe v1.4+, so filtering on it server-side would silently find nothing on
# older Safes. Instead every ExecutionSuccess event is fetched and matched
# client-side against whichever of topics[1] or the first word of `data`
# actually holds it.
find_execution_log() {
  local high=$to_block low match count

  while (( high >= from_block )); do
    low=$(( high - scan_window + 1 ))
    (( low < from_block )) && low=$from_block

    match=$(cast logs --address "$safe" --from-block "$low" --to-block "$high" --json "$EXECUTION_SUCCESS_TOPIC" \
      | jq -c --arg target "$safe_tx_hash" \
        '[.[] | select((.topics[1] // ("0x" + .data[2:66])) | ascii_downcase == $target)]')
    count=$(jq 'length' <<<"$match")

    if (( count > 1 )); then
      die 1 "found $count matching events for this SafeTxHash in blocks $low-$high, expected exactly one"
    elif (( count == 1 )); then
      jq -c '.[0]' <<<"$match"
      return 0
    fi

    (( low == from_block )) && break
    high=$(( low - 1 ))
  done
  return 1
}

log=$(find_execution_log) \
  || die 1 "no ExecutionSuccess event found for this Safe and SafeTxHash in blocks $from_block-$to_block. Check the chain ID, Safe address and SafeTxHash, or widen --from-block/--to-block if the transaction is older than the scanned range."

tx_hash=$(jq -r '.transactionHash' <<<"$log" | tr 'A-F' 'a-f')
block_number=$(cast to-dec "$(jq -r '.blockNumber' <<<"$log")")

tx=$(cast tx "$tx_hash" --json)
tx_to=$(jq -r '.to' <<<"$tx" | tr 'A-F' 'a-f')
[[ $tx_to == "${safe,,}" ]] \
  || die 1 "transaction $tx_hash was not sent directly to the Safe (to=$tx_to); this script only supports Safe transactions executed by a direct call to the Safe contract"

input=$(jq -r '.input' <<<"$tx" | tr 'A-F' 'a-f')
selector=${input:0:10}
[[ $selector == "$EXEC_TRANSACTION_SELECTOR" ]] \
  || die 1 "the transaction's calldata is not a direct execTransaction() call (selector $selector, expected $EXEC_TRANSACTION_SELECTOR); this script only supports Safe transactions executed by a direct call to the Safe contract"

# cast's plain (non-JSON) output appends a human-readable "[1.234e5]"
# annotation to large numbers; strip it before using the value as a number.
strip_annotation() { local v=$1; echo "${v%% \[*}"; }

mapfile -t fields < <(cast decode-calldata "$EXEC_TRANSACTION_SIG" "$input")
(( ${#fields[@]} == 10 )) \
  || die 1 "unexpected execTransaction() decode: got ${#fields[@]} fields, expected 10"

to=${fields[0]}
value=$(cast to-hex "$(strip_annotation "${fields[1]}")")
data=${fields[2],,}
operation=$(strip_annotation "${fields[3]}")
safe_tx_gas=$(cast to-hex "$(strip_annotation "${fields[4]}")")
base_gas=$(cast to-hex "$(strip_annotation "${fields[5]}")")
gas_price=$(cast to-hex "$(strip_annotation "${fields[6]}")")
gas_token=${fields[7]}
refund_receiver=${fields[8]}

# The engine evaluates a transaction against the state right before it lands,
# so the spec's "block" is the block prior to the one that mined it, not the
# mining block itself.
reference_block=$((block_number - 1))

nonce=$(cast to-hex "$(strip_annotation "$(cast call "$safe" 'nonce()(uint256)' --block "$reference_block")")")

spec=$(jq -n \
  --arg chainId "$(cast to-hex "$chain_id")" \
  --arg safe "$safe" \
  --arg to "$to" \
  --arg value "$value" \
  --arg data "$data" \
  --argjson operation "$operation" \
  --arg safeTxGas "$safe_tx_gas" \
  --arg baseGas "$base_gas" \
  --arg gasPrice "$gas_price" \
  --arg gasToken "$gas_token" \
  --arg refundReceiver "$refund_receiver" \
  --arg nonce "$nonce" \
  --arg block "$(cast to-hex "$reference_block")" \
  --arg verdict "$verdict" \
  --arg rule "$rule" \
  --arg note "$note" \
  --arg exampleTransaction "$tx_hash" \
  '{
    request: {
      block: $block,
      transaction: {
        chainId: $chainId, safe: $safe, to: $to, value: $value, data: $data,
        operation: $operation, safeTxGas: $safeTxGas, baseGas: $baseGas,
        gasPrice: $gasPrice, gasToken: $gasToken, refundReceiver: $refundReceiver,
        nonce: $nonce
      }
    },
    response: { verdict: $verdict, rule: $rule },
    metadata: { note: $note, exampleTransaction: $exampleTransaction }
  }
  | (.response |= with_entries(select(.value != "" and .value != null)))
  | (.metadata |= with_entries(select(.value != "" and .value != null)))
  | if (.metadata | length) == 0 then del(.metadata) else . end')

[[ -n $name ]] || name="${safe}_$(cast to-dec "$nonce")"
path="$ROOT/specs/$category/$name.json"

if [[ -e $path ]]; then
  [[ $force == true ]] || die 1 "$path already exists, pass --force to overwrite"
  rm -f -- "$path"
fi

mkdir -p -- "$(dirname -- "$path")"
jq . <<<"$spec" >"$path"
printf '\n' >>"$path"

if ! "$ROOT/bin/check-specs.sh" --fix "specs/$category/$name.json"; then
  rm -f -- "$path"
  die 1 "the crafted spec failed validation, nothing was written"
fi

echo "specs/$category/$name.json"
