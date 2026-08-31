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

def root_properties: ["request", "response", "metadata"];
def required_properties: ["request", "response"];

def request_properties: ["block", "transaction"];
def response_properties: ["verdict", "rule"];
def metadata_properties: ["note", "exampleTransaction"];

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
    "request.transaction: expected an object, got \(.transaction | abbrev)"
  else
    .transaction
    | ((keys_unsorted - transaction_properties)[] | "request.transaction: unknown property \"\(.)\""),
      ((transaction_properties - keys_unsorted)[] | "request.transaction: missing property \"\(.)\""),
      (to_entries[]
        | select(.key | IN(address_properties[])) | select(.value | address | not)
        | "request.transaction.\(.key): not an Address, got \(.value | abbrev)"),
      (to_entries[]
        | select(.key | IN(quantity_properties[])) | select(.value | quantity | not)
        | "request.transaction.\(.key): not a Quantity, got \(.value | abbrev)"),
      (select(has("data") and (.data | bytes | not))
        | "request.transaction.data: not Bytes, got \(.data | abbrev)"),
      (select(has("operation") and (.operation | IN(0, 1) | not))
        | "request.transaction.operation: expected 0 (CALL) or 1 (DELEGATECALL), got \(.operation | abbrev)")
  end;

def check_block:
  select(has("block") and (.block | quantity | not))
  | "request.block: not a Quantity, got \(.block | abbrev)";

def check_request:
  if has("request") | not then empty
  elif (.request | type) != "object" then
    "request: expected an object, got \(.request | abbrev)"
  else
    .request
    | ((keys_unsorted - request_properties)[] | "request: unknown property \"\(.)\""),
      ((request_properties - keys_unsorted)[] | "request: missing property \"\(.)\""),
      (check_transaction, check_block)
  end;

# "abstain" is a valid engine response but never a valid expectation: a vector
# asserts a definitive answer.
def check_response:
  if has("response") | not then empty
  elif (.response | type) != "object" then
    "response: expected an object, got \(.response | abbrev)"
  else
    .response
    | ((keys_unsorted - response_properties)[] | "response: unknown property \"\(.)\""),
      ((["verdict"] - keys_unsorted)[] | "response: missing property \"\(.)\""),
      (if has("verdict") | not then empty
      elif (.verdict | IN("secure", "insecure") | not) then
        "response.verdict: expected \"secure\" or \"insecure\", got \(.verdict | abbrev)"
      elif .verdict == "insecure" then
        if has("rule") | not then "response.rule: required when verdict is \"insecure\""
        elif .rule | rule_id | not then
          "response.rule: not a Charter rule citation such as \"R-4.3\", got \(.rule | abbrev)"
        else empty
        end
      elif has("rule") then "response.rule: must be absent when verdict is \"secure\""
      else empty
      end)
  end;

def check_metadata:
  if has("metadata") | not then empty
  elif (.metadata | type) != "object" then
    "metadata: expected an object, got \(.metadata | abbrev)"
  else
    .metadata
    | ((keys_unsorted - metadata_properties)[] | "metadata: unknown property \"\(.)\""),
      (select(has("note") and (.note | type) != "string")
        | "metadata.note: not a string, got \(.note | abbrev)"),
      (select(has("exampleTransaction") and (.exampleTransaction | digest | not))
        | "metadata.exampleTransaction: not a Digest, got \(.exampleTransaction | abbrev)")
  end;

if type != "object" then "expected a JSON object, got \(abbrev)"
else check_root, check_request, check_response, check_metadata
end
