# lib/canonical.jq — the one permitted on-disk form of a spec file.
#
# Projects a spec into canonical key order; emit it with `jq --indent 2 -f`.
# The order is chosen as follows: request (the reference block, then the
# SafeTransaction fields in Safe struct order), then response (the verdict,
# then the rule it cites), then metadata (the note explaining it, then the
# hash of the real transaction this vector is modelled on, if any).

def compact: with_entries(select(.value != null));

{
  request: (
    .request
    | {
      block,
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
      )
    }
  ),
  response: (
    .response
    | {
      verdict,
      rule
    }
    | compact
  ),
  metadata: (
    .metadata
    | {
      note,
      exampleTransaction
    }
    | compact
  )
}
# metadata is optional as a whole: drop it rather than leave an empty object
# when the input had no note and no exampleTransaction.
| if (.metadata | length) == 0 then del(.metadata) else . end
