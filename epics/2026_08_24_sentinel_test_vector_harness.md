# Plan: Sentinel test vector harness

Component: repository root. Introduces the `specs/` test-vector corpus, `bin/` entry points (`check-specs.sh`, `run-tests.sh`), a `lib/` directory of shared Bash/jq helpers, and a GitHub Actions CI workflow.

---

## Overview

This repository publishes test vectors for Safenet sentinels: Safe transactions paired with the verdict a correct sentinel engine is expected to return for them. Today it contains only `README.md` and `LICENSE`.

The epic delivers three things:

1. **A spec file format** — `specs/<group>/<case>.json`, holding a `SafeTransaction` plus its expected verdict, with a canonical on-disk representation and a documented schema.
2. **`bin/check-specs.sh`** — validates that every spec file is canonically formatted and schema-conformant. Runs in CI. Requires no network and no sentinel engine.
3. **`bin/run-tests.sh`** — replays specs against a live sentinel engine over HTTP and reports a per-group scorecard. Not run by this repository's CI; the sentinel engine repositories consume it.

Split into five PRs:

| PR  | Purpose                                        | Depends on |
| --- | ---------------------------------------------- | ---------- |
| 1   | Spec format documentation + seed corpus        | —          |
| 2   | `bin/check-specs.sh`, `lib/`, jq programs      | 1          |
| 3   | CI workflow                                    | 2          |
| 4   | `bin/run-tests.sh` (serial)                    | 2          |
| 5   | `--parallel=N` parallelism for `run-tests.sh`  | 4          |

PRs 3 and 4 are independent of each other and can be reviewed in parallel once PR 2 lands.

---

## Architecture Decision

**Dependency budget: `bash`, `jq`, `curl`, and coreutils only.** No test framework, no Node/Python, no vendored JSON Schema validator. The consequences are threaded through every decision below.

**`lib/spec.jq` is the definition of the spec format.** There is no machine-readable API contract in this repository to derive validation from, and no generation step. The schema is written once, directly, as a jq program that emits a list of human-readable error strings, with the prose description in `README.md` alongside it. The wire types it encodes (`Address`, `Quantity`, `Bytes`, `Digest`, `Operation`) originate in the sentinel engine API and are recorded in full under Tech Specs below.

**Canonical formatting is defined by an explicit jq reordering filter** (`lib/canonical.jq`), not by `jq -S`. The filter projects each object into a fixed key order — the `SafeTransaction` fields in Safe struct order, then `verdict`, `rule`, `note`, `txHash` — at 2-space indent. `note` sits directly after the verdict it explains; `txHash` trails as reference metadata. This keeps files deterministic _and_ readable, at the cost of needing a one-line filter update whenever `SafeTransaction` gains a field. `bin/check-specs.sh --fix` rewrites files into canonical form so contributors never hand-format.

**File comparison avoids `diff`/`cmp`.** Formatting violations are detected by comparing command-substitution strings in pure Bash, using a sentinel-character trick to make the trailing newline significant:

```bash
# $(...) strips trailing newlines, so append a sentinel to make them observable.
expected="$(jq --indent 2 -f "$ROOT/lib/canonical.jq" -- "$file"; printf x)"
actual="$(cat -- "$file"; printf x)"
[[ "$expected" == "$actual" ]] || fail "not canonically formatted (run bin/check-specs.sh --fix)"
```

`bin/check-specs.sh` reports _which_ file is misformatted and how to fix it, rather than rendering a diff.

**Parallelism uses Bash job control, not `xargs -P`.** `--parallel=N` is implemented with a `wait -n` throttle (Bash 4.3+; the toolchain here is 5.2), keeping the dependency set at `jq` + `curl`. Each worker writes its outcome to a file in a `mktemp -d` scratch directory; the parent reads those files back **in spec order** after all workers finish, so output is byte-identical regardless of `N`. The trade-off is no streaming progress under `--parallel=N` — accepted, because reproducible output matters more for a conformance suite than live feedback.

**Executables live in `bin/`, sourced helpers in `lib/`, both alongside `specs/` at the repository root.** The two entry points are `bin/check-specs.sh` and `bin/run-tests.sh`; nothing executable sits at the top level.

Because the scripts are no longer next to the data they operate on, each one resolves the repository root from its own location rather than trusting the working directory:

```bash
ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
```

Every path is then built from `$ROOT` — `$ROOT/specs`, `$ROOT/lib/spec.jq` — so `./bin/check-specs.sh` and `../../bin/check-specs.sh` behave identically from any directory. Spec paths are still *displayed* root-relative (`specs/group/case.json`), because that is what a contributor types back in as an operand. The limitation of `cd -P` over `readlink -f` is that symlinking an entry point into `PATH` resolves `$ROOT` to the symlink's directory and breaks; that is a documented non-use, not a bug to work around.

**`lib/common.sh` holds the shared spec-resolution logic**, since both entry points accept the same `[specs...]` argument grammar. It is sourced, not executed.

**Group names are never enumerated outside `specs/`.** The taxonomy has no settled guidance yet and is expected to be reorganised as the corpus grows, so nothing is allowed to hard-code it: `resolve_specs` discovers groups by globbing, CI runs the whole tree rather than a list of groups, no manifest file names them, and no spec references another spec. Reorganising is then a pure `git mv` plus a review of the new names. The one unavoidable cost is that a spec's identity **is** its path — moving a case renames it in `bin/run-tests.sh` output and breaks any external link to it — which argues for getting the granularity roughly right early even though it is cheap to change mechanically.

### Alternatives Considered

- **A JSON Schema file plus a validator** (`ajv`, `check-jsonschema`): the cleanest single source of truth. Rejected — pulls in Node or Python, well outside the dependency budget.
- **`jq -S --indent 2` for canonical form**: a self-maintaining one-liner needing no updates when fields are added. Rejected — alphabetical order reads poorly for this data (`note`, `rule`, `transaction`, `txHash`, `verdict`) and buries `verdict`, the single most important field, at the bottom of the file.
- **A sidecar `<case>.md` per vector instead of a `note` field**: room for long-form rationale with Markdown formatting. Rejected — doubles the file count, lets prose drift out of sync with the spec it describes, and `run-tests.sh` would have to go read a second file to quote rationale on failure.
- **Only enforcing indentation, preserving author key order**: least churn. Rejected — key order would drift across the corpus, making review diffs noisier over time.
- **`xargs -P` for `--parallel=N`**: less Bash to review and battle-tested throttling. Rejected to hold the dependency line; also awkward to thread per-item outcome codes back out of `xargs`.
- **TAP output from `run-tests.sh`**: machine-readable and CI-friendly. Deferred — plain human-readable output first; TAP can be added later behind an env var without changing the documented usage string.
- **A single aggregate pass percentage instead of a per-group scorecard**: one number, trivially comparable between engines and across time. Rejected — it collapses exactly the information an engine author needs, which is _where_ the gaps are. A group-level table makes partial coverage legible, in the way a browser-compatibility matrix does.
- **Reporting `abstain` as a `FAIL`**: fewer outcome categories and the same exit code, since a skip is not a full pass either way. Rejected — collapsing them destroys the distinction between an engine that answered wrongly and one that declined to answer, which is the single most useful signal for an engine author reading the output.
- **Storing all vectors in one large JSON file**: fewer files to manage. Rejected — one case per file gives clean per-case diffs, lets `run-tests.sh` name failures by path, and makes the `group`/`group/case.json` selector grammar natural.

---

## Tech Specs

### Repository layout

<!-- prettier-ignore -->
```
bin/check-specs.sh          entry point: validate the corpus
bin/run-tests.sh            entry point: replay the corpus against an engine
lib/common.sh               sourced: spec resolution, usage/error helpers
lib/canonical.jq            canonical key-order projection
lib/spec.jq                 schema validator
specs/<group>/<case>.json   the test vectors
.github/workflows/ci.yml    static checks
```

Nothing executable sits at the repository root. Both entry points are marked executable and carry a `#!/usr/bin/env bash` shebang, so they are invoked as `./bin/check-specs.sh` rather than `bash bin/check-specs.sh`.

### Spec file format

Path: `specs/<group>/<case>.json`. Groups are thematic — a group holds both secure and insecure cases exercising the same behaviour — e.g. `specs/delegatecall/`, `specs/gas-refund/`, `specs/token-approval/`. Groups are deliberately _not_ named after rule IDs; there will be more groups than there are rules, and a group needs to hold the negative controls for its own positive cases.

<!-- prettier-ignore -->
```json
{
  "transaction": {
    "chainId": "0x1",
    "safe": "0x5aFE3855358E112B5647B952709E6165e1c1eEEe",
    "to": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    "value": "0x0",
    "data": "0xd0e30db0",
    "operation": 0,
    "safeTxGas": "0x0",
    "baseGas": "0x0",
    "gasPrice": "0x0",
    "gasToken": "0x0000000000000000000000000000000000000000",
    "refundReceiver": "0x0000000000000000000000000000000000000000",
    "nonce": "0x0"
  },
  "verdict": "insecure",
  "rule": "R-4.1",
  "note": "Delegatecalls to an unaudited target let it rewrite the Safe's owner set.",
  "txHash": "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
}
```

Schema, as enforced by `lib/spec.jq`:

- Root is an object with no properties beyond `transaction`, `verdict`, `rule`, `note`, `txHash`. `transaction` and `verdict` are required.
- `transaction` is an object with **exactly** the twelve `SafeTransaction` properties listed above — no extras, none missing. Field patterns:
    - `Address` (`safe`, `to`, `gasToken`, `refundReceiver`): `^0x[0-9a-fA-F]{40}$`
    - `Quantity` (`chainId`, `value`, `safeTxGas`, `baseGas`, `gasPrice`, `nonce`): `^0x([1-9a-f][0-9a-f]*|0)$` — minimal, lower-case, no leading zeros; zero is `"0x0"`
    - `Bytes` (`data`): `^0x([0-9a-f]{2})*$` — lower-case; empty is `"0x"`
    - `Operation` (`operation`): integer `0` (CALL) or `1` (DELEGATECALL)
- `verdict` is `"secure"` or `"insecure"`. **`"abstain"` is not a valid expected verdict** — a test vector asserts a definitive answer; abstaining is an engine behaviour, not ground truth.
- `rule` is required when `verdict` is `"insecure"` and **must be absent** otherwise. Pattern `^R-[0-9]+\.[0-9]+$` (i.e. `R-4.1`).
- `note` is optional: human-readable prose explaining the rationale behind the verdict — why this transaction is insecure, or why a superficially suspicious one is fine. Validated only as a non-empty string containing no control characters (newlines included), so it stays on one line and survives canonical formatting without `\n` escapes. Valid for both verdicts, and strongly encouraged on any non-obvious vector.
- `txHash` is optional, pattern `^0x[0-9a-f]{64}$`. It records a real on-chain transaction corresponding to the vector, **for documentation purposes only** — nothing validates it against `transaction`, and `run-tests.sh` does not consult it.

### `bin/check-specs.sh`

```
Usage: bin/check-specs.sh [--fix] [specs...]
```

`--fix` rewrites each file into canonical form instead of reporting formatting violations; schema errors are still reported and are never auto-fixed. Per file, in order: parseable JSON → schema conformant (`lib/spec.jq`) → canonically formatted. Errors are printed as `specs/group/case.json: <message>`, one per line, and every file is checked before exiting (no early bail).

Exit codes: `0` all clean; `1` one or more files invalid; `2` usage or spec-resolution error.

`lib/spec.jq` sketch:

```jq
def addr: type == "string" and test("^0x[0-9a-fA-F]{40}$");
def qty:  type == "string" and test("^0x([1-9a-f][0-9a-f]*|0)$");
# ... bytes, digest, rule ...

def check_tx:
  [ if type != "object" then "transaction: not an object" else empty end
  , (keys_unsorted - $TX_FIELDS | .[] | "transaction.\(.): unknown property")
  , ($TX_FIELDS - keys_unsorted | .[] | "transaction.\(.): missing")
  , (if (.safe? | addr) then empty else "transaction.safe: not an Address" end)
  # ...
  ];

[ check_root, check_tx, check_verdict ] | flatten
```

The script feeds the resulting array to Bash line by line; an empty array means the file is valid.

### `bin/run-tests.sh`

```
Usage: bin/run-tests.sh [--parallel=N] [--sentinel-engine-url=URL] [--sentinel-timeout=SECONDS] [specs...]
```

Only the long `--option=value` form is accepted — no short aliases, no space-separated values. Parsing reduces to one `case` over `"${1%%=*}"` taking the value from `"${1#*=}"`: no lookahead, no `shift 2`, and no ambiguity about whether the following word is a value or a spec path.

Every option has an environment-variable fallback. **Command-line arguments take precedence over the environment, which takes precedence over the default.** Supplying a value both ways is not an error and produces no warning; the flag simply wins.

| Option                        | Environment           | Default                 | Meaning                                                                                                                                                                   |
| ----------------------------- | --------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--parallel=N`                | `SENTINEL_PARALLEL`   | `1`                     | Run up to `N` specs concurrently. Positive integer.                                                                                                                       |
| `--sentinel-engine-url=URL`   | `SENTINEL_ENGINE_URL` | `http://localhost:5473` | Engine **base** URL; the script appends `/v1/security-check` (any trailing `/` is stripped). The versioned path is part of the API contract, not the operator's to choose. |
| `--sentinel-timeout=SECONDS`  | `SENTINEL_TIMEOUT`    | `30`                    | Per-request budget in **seconds**. Positive integer.                                                                                                                      |

Environment names are uniformly `SENTINEL_`-prefixed — including `SENTINEL_PARALLEL`, where the prefix is not implied by the option name — so none of them collide with generic names other tools already claim (`PARALLEL` is GNU parallel's).

Values are validated identically whichever source they came from, and the diagnostic names that source, so a stale exported variable is not mistaken for a bad flag:

```
--parallel: expected a positive integer, got "x"
SENTINEL_PARALLEL: expected a positive integer, got "x"
```

`--sentinel-timeout` is in seconds because that is the unit a person reaches for on a command line, whereas the engine API's `x-request-timeout` header is in milliseconds — the script multiplies by 1000 when building the header. `curl --max-time` gets the budget plus one second of grace, so an engine that legitimately consumes its full allowance is not severed by the client at the moment it answers.

Per spec file:

1. Build the request body with `jq -c '{transaction}'`.
2. `POST` it with `Content-Type: application/json`. The optional `x-request-id` header is not sent — it identifies a Safenet proposal, which a replayed vector does not have.
3. Capture body and status together via `curl -sS -w '\n%{http_code}'`; split in Bash.
4. Compare the response's `verdict` (and `rule`, when `insecure`) against the spec.

Outcomes:

| Outcome  | Condition                                                                                                                                                                                            |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PASS`   | verdict matches; for `insecure`, `rule` matches exactly                                                                                                                                              |
| `FAIL`   | verdict differs; or verdict is `insecure` with a different `rule`; or the request errored — transport failure, non-`200` status, unparseable body, or a body that is not a recognised verdict object |
| `SKIP`   | engine returned `{"verdict":"abstain"}`                                                                                                                                                              |

Request and protocol errors are `FAIL`, not a separate outcome — an engine that cannot be reached is not passing the vector. The cause is carried in the reported message (`FAIL specs/gas-refund/basic.json: HTTP 502`) so an unreachable engine is still distinguishable at a glance from a wrong verdict, without a fourth counter.

On `FAIL` and `SKIP`, the spec's `note` is quoted beneath the outcome line when present, so an engine author reading the output gets the rationale for the expected verdict without opening the spec file:

```
FAIL specs/delegatecall/unaudited-target.json: expected insecure (R-4.1), got secure
     Delegatecalls to an unaudited target let it rewrite the Safe's owner set.
```

Notes are not printed for `PASS` — they would drown the signal on a green run.

`SKIP` covers `abstain`. It is reported separately from `FAIL` because "declined to answer" and "answered wrongly" are different diagnoses for an engine author, but it is **not** a pass.

The run ends with a scorecard: one row per group, giving that group's percentage in each of the three categories, plus a total row. The shape is deliberately that of a browser-compatibility table — the useful question about a sentinel engine is usually not "does it pass" but "which areas does it cover", and a per-group breakdown answers that at a glance while a single aggregate number hides it.

<!-- prettier-ignore -->
```
GROUP                 TESTS   PASSED   FAILED  SKIPPED
delegatecall              6      67%      33%       0%
gas-refund                4     100%       0%       0%
token-approval            7      43%      14%      43%
------------------------------------------------------
TOTAL                    17      65%      18%      18%
```

Only groups included in the current selection appear, so `./bin/run-tests.sh delegatecall` prints a one-row table. Rows are in the same `LC_ALL=C` order as spec resolution. The `GROUP` column is sized to the longest group name present, everything else is fixed-width, and the whole table is emitted with `printf` — no external formatting tool.

Percentages are per-group shares of that group's own test count, not of the corpus, so a small group is not visually drowned by a large one. Each row's three values sum to 100% before rounding.

**A full pass is 100% passed, 0% failed, 0% skipped.** Exit codes: `0` only when every test passed; `1` when any test failed or was skipped; `2` usage error, an invalid option or environment value, or spec-resolution error. An engine that abstains on everything therefore does not pass the suite. In practice a partially-compliant engine is the normal case, so the scorecard is the primary output and the exit code is a convenience for callers that want a hard gate.

### Spec selector grammar (`lib/common.sh`)

`resolve_specs` maps the `[specs...]` operands to a sorted, de-duplicated file list:

- No operands, or the single operand `all` → every `specs/*/*.json`.
- `<group>` → every `specs/<group>/*.json`; error if the group has no cases.
- `<group>/<case>.json` → that one file.
- The `specs/` prefix is accepted and stripped on both forms (`specs/delegatecall`, `specs/delegatecall/basic.json`), so shell tab-completion output works verbatim.
- Any operand resolving to nothing is a hard error listing the bad operand — never a silent empty run.

Ordering is `LC_ALL=C` for reproducibility across machines.

### CI

`.github/workflows/ci.yml`, on push and pull request. Static checks only — no network, no engine:

- `./bin/check-specs.sh`
- `shellcheck` on `bin/*.sh` and `lib/common.sh` (CI-only lint; pre-installed on GitHub-hosted runners, never needed to use the repository)
- `bash -n` on the same files

**`bin/run-tests.sh` is deliberately not exercised here.** Replaying the corpus against an engine is the job of CI in the sentinel engine repositories, which have an engine to point at; this repository only guarantees that the corpus is well-formed and the scripts are lint-clean. The consequence is that no job in this repository can detect the harness diverging from a real engine — see Assumptions.

---

## Implementation Phases

### Phase 1 — Spec format and seed corpus

Documentation and data only; no executable code, so review can focus entirely on whether the format is right.

- `README.md` — add "Spec format" and "Usage" sections: the schema and its wire types, the `specs/<group>/<case>.json` layout, group naming convention, both scripts' usage strings, and the option/environment/default table for `bin/run-tests.sh`.
- `specs/` — 4–6 seed cases across two groups, hand-written in canonical form, covering: a `secure` case, an `insecure` case with `rule`, a case with `txHash`, a case without, a case with `note`, a case without, and `operation: 1`.

Files: 1 modified, ~6 added.

### Phase 2 — `bin/check-specs.sh`

- `lib/common.sh` — `resolve_specs`, usage/error helpers.
- `lib/canonical.jq` — canonical key-order projection.
- `lib/spec.jq` — schema validator emitting error strings.
- `bin/check-specs.sh` — root resolution, driver, `--fix`, formatting comparison, exit codes.

Verified against Phase 1's corpus (must pass clean) plus deliberately broken files created ad hoc and not committed.

Files: 4 added (1 under `bin/`, 3 under `lib/`). Largest PR of the epic; if `lib/spec.jq` alone pushes it past ~300 lines, split the two jq programs (`lib/canonical.jq` + formatting check) from the schema validator into two PRs.

### Phase 3 — CI workflow

- `.github/workflows/ci.yml` — `bin/check-specs.sh`, `shellcheck`, `bash -n`.

Files: 1 added. Independent of Phase 4. Infrastructure only, kept separate so it does not ride along with feature work.

### Phase 4 — `bin/run-tests.sh`, serial

Full functionality except `--parallel=N`, which is accepted and validated but only honours `N=1`; any other value errors with "not yet implemented". This keeps HTTP handling and verdict semantics — the parts worth arguing about — in a PR with no concurrency in it.

- `bin/run-tests.sh` — option and argument parsing with environment fallbacks, request construction, `curl` invocation, verdict comparison, per-test reporting, per-group scorecard, exit codes.
- `lib/common.sh` — extend only if Phase 2's helpers need generalising.

Files: 1 added, 0–1 modified.

### Phase 5 — `--parallel=N` parallelism

- `bin/run-tests.sh` — `wait -n` throttle, `mktemp -d` scratch directory, `trap`-based cleanup on exit and interrupt, in-order result collection.

Files: 1 modified. Small and self-contained: a reviewer checks the concurrency and cleanup logic alone, having already accepted the semantics in Phase 4. Verify output is byte-identical across `--parallel=1`, `--parallel=4`, and `--parallel=16` against a local engine.

### Follow-up (out of scope, not blocking)

Growing the corpus is ongoing work in its own PRs, one group at a time, and does not gate this epic. Delete `epics/2026_08_24_sentinel_test_vector_harness.md` when Phase 5 lands.

---

## Open Questions and Assumptions

**Assumptions**

- `--sentinel-engine-url` takes a base URL and the script owns the `/v1/security-check` path. If engines are deployed at arbitrary full paths, this needs revisiting.
- Options may be interleaved with spec operands but `--` is honoured as an end-of-options marker, so a spec path beginning with `-` is still addressable.
- Rule comparison for `insecure` verdicts is exact string equality. An engine citing a _different_ rule for a transaction the spec agrees is insecure is a `FAIL`, not partial credit.
- Percentages in the scorecard are integers, rounded, and computed with `jq` (Bash has no float arithmetic). They are cosmetic; the counts and exit code are authoritative, so rounding artefacts are acceptable — on a 3-case group, `33% / 33% / 33%` will not visibly sum to 100%.
- Vectors are chain-agnostic in the sense that `chainId` is data in the spec; there is no per-run chain override.
- Bash 4.3+ (`wait -n`) is available wherever `bin/run-tests.sh` runs. Confirmed 5.2 on the development machine; worth a note in the README.
- Output is plain text for humans. No JSON or TAP report in this epic.
- `note` is prose and its content is unvalidated beyond "non-empty, single line" — nothing checks that it actually describes the verdict, or that it stays accurate if the verdict is later revised. It is a review-time concern, not a tooling one.
- `txHash` is documentation only, so a wrong-but-well-formed hash is undetectable. Accepted: verifying it would need keccak256 and EIP-712, which `jq` cannot do.
- **Drift between `lib/spec.jq` and the engine API is detected downstream, if at all.** Nothing ties the spec format's wire types to the upstream contract, and no job in this repository replays the corpus against an engine, so a divergence surfaces as a pass-rate drop in whichever sentinel engine repository runs the suite. A comment in `lib/spec.jq` names the upstream source for whoever goes looking. The residual gap: a divergence affecting few vectors is a small dip rather than an obvious wall, and it is seen by engine authors rather than by whoever introduced it here.
- **The group taxonomy is expected to change.** There is no settled guidance on how groups should be structured, so the plan treats reorganisation as routine rather than exceptional — see the glob-discovery constraint under Architecture Decision. Phase 1's seed groups set no binding precedent.
- **Vectors may land ahead of engine support.** A sentinel that does not yet implement a rule simply scores lower in the affected group; nothing in this repository goes red. This is what makes the scorecard the primary output and the exit code a secondary convenience, and it is why no "expected to fail" marker is needed in the spec format.
- Group order in the scorecard is the same `LC_ALL=C` order used for spec resolution, so two runs over the same selection produce identical tables.

**Open questions**

None outstanding.
