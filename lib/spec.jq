# lib/spec.jq — the schema check that actually runs.
#
# schema.json is the definition of a spec file, for JSON Schema tooling. This is
# a hand-maintained transcription of it, because validating JSON Schema properly
# would mean a dependency this repository does not want.
#
# Emits one human-readable string per violation, so no output means the spec is
# valid.

def address:  type == "string" and test("^0x[0-9a-fA-F]{40}$");
def quantity: type == "string" and test("^0x([1-9a-f][0-9a-f]*|0)$");
def bytes:    type == "string" and test("^0x([0-9a-f]{2})*$");
def digest:   type == "string" and test("^0x[0-9a-f]{64}$");
def rule_id:  type == "string" and test("^R-[0-9]+\\.[0-9]+$");

# Values are quoted back to the author, shortened so a 600-byte calldata blob
# does not bury the message attached to it.
def abbrev: tojson | if length > 44 then .[0:41] + "..." else . end;

def root_properties: ["transaction", "verdict", "rule", "note", "txHash"];
def required_properties: ["transaction", "verdict"];

# Canonical order, mirrored by lib/canonical.jq.
def transaction_properties: [
  "chainId", "safe", "to", "value", "data", "operation",
  "safeTxGas", "baseGas", "gasPrice", "gasToken", "refundReceiver", "nonce"
];
def address_properties: ["safe", "to", "gasToken", "refundReceiver"];
def quantity_properties: ["chainId", "value", "safeTxGas", "baseGas", "gasPrice", "nonce"];

def check_root:
  ((keys_unsorted - root_properties)[] | "unknown property \"\(.)\""),
  ((required_properties - keys_unsorted)[] | "missing required property \"\(.)\"");

def check_transaction:
  if has("transaction") | not then empty
  elif (.transaction | type) != "object" then
    "transaction: expected an object, got \(.transaction | abbrev)"
  else
    .transaction
    | ((keys_unsorted - transaction_properties)[] | "transaction: unknown property \"\(.)\""),
      ((transaction_properties - keys_unsorted)[] | "transaction: missing property \"\(.)\""),
      (to_entries[]
        | select(.key | IN(address_properties[])) | select(.value | address | not)
        | "transaction.\(.key): not an Address, got \(.value | abbrev)"),
      (to_entries[]
        | select(.key | IN(quantity_properties[])) | select(.value | quantity | not)
        | "transaction.\(.key): not a Quantity, got \(.value | abbrev)"),
      (select(has("data") and (.data | bytes | not))
        | "transaction.data: not Bytes, got \(.data | abbrev)"),
      (select(has("operation") and (.operation | IN(0, 1) | not))
        | "transaction.operation: expected 0 (CALL) or 1 (DELEGATECALL), got \(.operation | abbrev)")
  end;

# "abstain" is a valid engine response but never a valid expectation: a vector
# asserts a definitive answer.
def check_verdict:
  if has("verdict") | not then empty
  elif (.verdict | IN("secure", "insecure") | not) then
    "verdict: expected \"secure\" or \"insecure\", got \(.verdict | abbrev)"
  elif .verdict == "insecure" then
    if has("rule") | not then "rule: required when verdict is \"insecure\""
    elif .rule | rule_id | not then
      "rule: not a Charter rule citation such as \"R-4.3\", got \(.rule | abbrev)"
    else empty
    end
  elif has("rule") then "rule: must be absent when verdict is \"secure\""
  else empty
  end;

def check_documentation:
  (select(has("note") and (.note | type) != "string")
    | "note: not a string, got \(.note | abbrev)"),
  (select(has("txHash") and (.txHash | digest | not))
    | "txHash: not a Digest, got \(.txHash | abbrev)");

if type != "object" then "expected a JSON object, got \(abbrev)"
else check_root, check_transaction, check_verdict, check_documentation
end
