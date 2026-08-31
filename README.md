# Safenet Sentinel Test Vectors

This repository contains a collection of test Safe transactions and their expected verdicts. It is intended as a resource for sentinels in order to check the quality of their engine.

## Layout

All test vectors are files `specs/<group>/<case>.json`. They are organised into thematic groups that can be run together.

## Spec format

Each vector is one JSON file with three top-level sections, mirroring the engine's own API: `request` is what a sentinel is sent, `response` is what it must answer, and `metadata` is documentation that plays no part in the check itself.

The machine-readable definition is available in [`schema.json`](schema.json) for use with JSON schema compatible tools.

### `request`

Required. The engine's input: `block`, the reference block to evaluate against, and `transaction`, the Safe transaction under test.

#### `request.block`

Required block number on `request.transaction.chainId`: the block the engine should evaluate `request.transaction` against. In case a vector is derived from an onchain transaction, this is the block before it was included, as the check would have happened before the transaction execution. For a vector with no real transaction behind it, this is the chain's latest block as of when the vector was written.

`bin/run-tests.sh` sends `request` to the engine verbatim.

### `response`

Required. The answer a correct engine gives for `request`: `verdict` (`"secure"` or `"insecure"`), and, when insecure, the `rule` it cites.

### `metadata`

Optional, and read by nothing but humans: neither `bin/run-tests.sh` nor the engine ever sees it.

#### `metadata.note`

Optional prose explaining the rationale behind the verdict: why this transaction is insecure, or why a superficially alarming one is fine.

#### `metadata.exampleTransaction`

Optional hash of a real on-chain transaction corresponding to this vector.

This is for **documentation only**, a pointer to a block explorer for whoever is investigating the case. Nothing derives it from `request.transaction` or checks that the two agree.

### EOA Transactions

Some vectors are recast from a transaction an externally-owned account made rather than a Safe. Address poisoning mostly claims EOAs, and module exploits bypass the multisig entirely, but the decision a sentinel would have to make is the same one — so those incidents are represented here in the `SafeTransaction` shape:

- the acting account becomes `safe`, even though no Safe was deployed there;
- `to`, `value` and `data` are taken from the on-chain call;
- fields with no counterpart are neutral: `operation` is CALL, `safeTxGas`, `baseGas` and `gasPrice` are `0x0`, and `gasToken` and `refundReceiver` are the zero address;
- `nonce` is the account nonce.

Their notes begin with "EOA transaction." Read `safe` as the account whose funds were at risk, not as a claim that a Safe exists at that address.

## Canonical formatting

Spec files have exactly one permitted on-disk form: 2-space indent, one trailing newline, and keys in the order shown above — `request` (`block`, then the `SafeTransaction` fields in Safe struct order), then `response` (`verdict`, then `rule`), then `metadata` (`note`, then `exampleTransaction`).

Do not hand-format. `bin/check-specs.sh --fix` rewrites files into canonical form, and CI rejects anything that is not already in it.

`--fix` only touches specs that already satisfy the schema, a spec with schema errors is reported and left exactly as it was; fix those by hand first.

## Usage

Validate the corpus. Needs no network and no engine:

```sh
./bin/check-specs.sh              # all specs
./bin/check-specs.sh --fix        # rewrite into canonical form
./bin/check-specs.sh specs/address-poisoning
```

Replay the corpus against a running engine:

```sh
./bin/run-tests.sh
./bin/run-tests.sh --parallel=8 --sentinel-engine-url=https://sentinel.example
./bin/run-tests.sh specs/address-poisoning specs/settings-change/bybit-mastercopy-delegatecall.json
```

`bin/test-sentinel.py` is a dummy engine that answers every vector correctly by reading the corpus, so it scores 100% by construction. It exists so that CI can exercise `bin/run-tests.sh` without a real engine to point at:

```sh
./bin/test-sentinel.py &
./bin/run-tests.sh
```

Both scripts take the same spec operands: nothing (or `all`, the default) for the whole corpus, a `<group>`, or a `<group>/<case>.json`. A leading `specs/` is accepted, so tab-completed paths work as typed.

`bin/run-tests.sh` reports a per-group scorecard rather than a single verdict, because the useful question about an engine is usually which areas it covers, not whether it is perfect:

```
GROUP                 TESTS   PASSED   FAILED  SKIPPED
address-poisoning        12      75%      17%       8%
module-execution          1       0%     100%       0%
settings-change           2     100%       0%       0%
token-approval            1     100%       0%       0%
------------------------------------------------------
TOTAL                    16      75%      19%       6%
```

### Options

| Option                       | Environment           | Default                 | Meaning                                                  |
| ---------------------------- | --------------------- | ----------------------- | -------------------------------------------------------- |
| `--parallel=N`               | `PARALLEL`            | `1`                     | Run up to `N` specs concurrently.                        |
| `--sentinel-engine-url=URL`  | `SENTINEL_ENGINE_URL` | `http://localhost:5473` | Engine base URL; `/v1/security-check` is appended.       |
| `--sentinel-timeout=SECONDS` | `SENTINEL_TIMEOUT`    | `30`                    | Per-request budget. Sent as `x-request-timeout` (in ms). |

## Crafting a spec from a real transaction

`bin/craft-spec.sh` builds a spec from a Safe transaction that already executed 
onchain, given a chain ID, a Safe address and a SafeTxHash (the SafeTx struct hash a
Safe UI shows before signing, not the onchain transaction hash). It looks up the
Safe's `ExecutionSuccess` event for that hash, decodes the enclosing transaction's
`execTransaction()` calldata, recovers the nonce, and writes the result into
`specs/<category>/`, formatted and validated the same way `bin/check-specs.sh --fix`
would. It needs [Foundry's `cast`](https://book.getfoundry.sh/cast/) on `PATH`,
alongside the `jq` this repository already depends on:

```sh
RPC_URLS='{"1":"https://eth.example/rpc"}' \
  ./bin/craft-spec.sh \
    --chain-id 1 \
    --safe 0x888614448Eb7c766864faFb1Dd20ff0b47988a87 \
    --safe-tx-hash 0x1234...abcd \
    --verdict insecure \
    --rule R-4.3 \
    --category settings-change \
    --note "Optional prose explaining the rationale."
```

The verdict and, when insecure, the rule it cites cannot be derived from the chain —
those are always the caller's call. Run `./bin/craft-spec.sh --help` for the rest of
the options, including narrowing the block range searched for the execution event.
`ExecutionSuccess`'s `txHash` argument is only an indexed topic on Safe v1.4+; older
Safes emit it as part of the log's `data` instead, so the search filters by event
signature and Safe address alone and matches the hash client-side, transparently
handling both.

`RPC_URLS` is a JSON object mapping decimal chain IDs to RPC URLs, e.g.
`{"11155111":"https://...","100":"https://..."}`. The
[Craft spec from transaction](.github/workflows/craft-spec.yml) workflow runs the
same script from a manually triggered GitHub Action and opens a pull request with
the result; it expects `RPC_URLS` as a repository secret in that same shape.

Some free/public RPC endpoints cap `eth_getLogs` to a narrow block range (single
digits, in one case observed); `--scan-window` controls how wide a range this
script asks for at a time, so lower it if the provider rejects the default.
