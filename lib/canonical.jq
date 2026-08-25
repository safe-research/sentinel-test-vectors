# lib/canonical.jq — the one permitted on-disk form of a spec file.
#
# Projects a spec into canonical key order; emit it with `jq --indent 2 -f`.
# The order is chosen as follows: the SafeTransaction fields in Safe struct
# order, then the verdict, then the rule it cites, then the note explaining it,
# then the on-chain reference.

def compact: with_entries(select(.value != null));

{
  transaction: (
    .transaction
    | {
      chainId,
      safe,
      to,
      value,
      data,
      operation,
      safeTxGas,
      baseGas,
      gasPrice,
      gasToken,
      refundReceiver,
      nonce
    }
    | compact
  ),
  verdict,
  rule,
  note,
  txHash
}
| compact
