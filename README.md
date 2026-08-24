# Safenet Sentinel Test Vectors

This repository contains a collection of test Safe transactions and their expected verdicts. It is intended as a resource for sentinels in order to check the quality of their engine.

## Layout

All test vectors are files `specs/<group>/<case>.json`. They are organised into thematic groups that can be run together.

## Spec format

Each vector is one JSON file: a Safe transaction, the expected verdict, and optional documentation.

The machine-readable definition is available in [`schema.json`](schema.json) for use with JSON schema compatible tools.

### `note`

Optional prose explaining the rationale behind the verdict: why this transaction is insecure, or why a superficially alarming one is fine.

### `txHash`

Optional hash of a real on-chain transaction corresponding to this vector.

This is for **documentation only**, a pointer to a block explorer for whoever is investigating the case. Nothing derives it from `transaction` or checks that the two agree, and the test harness never reads it.

### EOA Transactions

Some vectors are recast from a transaction an externally-owned account made rather than a Safe. Address poisoning mostly claims EOAs, and module exploits bypass the multisig entirely, but the decision a sentinel would have to make is the same one — so those incidents are represented here in the `SafeTransaction` shape:

- the acting account becomes `safe`, even though no Safe was deployed there;
- `to`, `value` and `data` are taken from the on-chain call;
- fields with no counterpart are neutral: `operation` is CALL, `safeTxGas`, `baseGas` and `gasPrice` are `0x0`, and `gasToken` and `refundReceiver` are the zero address;
- `nonce` is the account nonce.

Their notes begin with "EOA transaction." Read `safe` as the account whose funds were at risk, not as a claim that a Safe exists at that address.

## Canonical formatting

Spec files have exactly one permitted on-disk form: 2-space indent, one trailing newline, and keys in the order shown above — the `SafeTransaction` fields in Safe struct order, then `verdict`, `rule`, `note`, `txHash`.

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

It exits `0` only on a clean sweep — 100% passed, nothing failed, nothing skipped.

### Options

| Option                       | Environment           | Default                 | Meaning                                                  |
| ---------------------------- | --------------------- | ----------------------- | -------------------------------------------------------- |
| `--parallel=N`               | `SENTINEL_PARALLEL`   | `1`                     | Run up to `N` specs concurrently.                        |
| `--sentinel-engine-url=URL`  | `SENTINEL_ENGINE_URL` | `http://localhost:5473` | Engine base URL; `/v1/security-check` is appended.       |
| `--sentinel-timeout=SECONDS` | `SENTINEL_TIMEOUT`    | `30`                    | Per-request budget. Sent as `x-request-timeout` (in ms). |
