# rust-quality

Shared Rust quality-gate toolchain for the fleet — **one canonical source** for
the lint block, the clippy/rustfmt/cargo-deny config, the static-analysis
scripts, and the CI gates. Consumed as a [mooncake](https://github.com/alehatsman/mooncake)
module. Sibling of `go-quality`; same shape, adapted where Rust differs.

It also carries the **guide**:

- [docs/RUST.md](docs/RUST.md) — how to write it. Rules, gate markers, the 2026 trap list, a review checklist.
- [docs/STACK.md](docs/STACK.md) — what to reach for. De-facto crate picks with versions, deviation triggers, and what we deliberately do not use.

## What's here

```
index.yml            module manifest (name + export → component map)
lints.toml           canonical [workspace.lints] block — the single source of truth
clippy.toml          lint tuning (test exemptions, thresholds, doc idents)
rustfmt.toml         formatting, stable options only
deny.toml            advisories + licenses + bans + sources policy
docs/
  RUST.md            the quality guide
  STACK.md           the crate picks
scripts/
  ai-lint.sh         AI-smell sweep (stub macros, agent TODOs, prompt artifacts)
  budget-status.sh   god-file + duplicate-dependency soft caps
  lints-check.sh     lint-block drift: consumer Cargo.toml vs lints.toml
  clippy-findings.sh clippy JSON diagnostics -> shared finding schema
  install-tools.sh   install the gate toolchain
  check-tools.sh     verify the toolchain is present
  ci/fast.sh         pre-commit gate  (lockfile + fmt + check + ai-lint + budget)
  ci/full.sh         pre-push gate    (fmt + build + clippy + test + doc + deny
                                       + machete + lints-check + budget)
```

## The lint block is not a file copy

`clippy.toml`, `rustfmt.toml` and `deny.toml` are dropped into the consumer by
`rq/sync-config`. The lint levels cannot be: **cargo has no include mechanism
for manifests**. So `lints.toml` is the canonical text, `rq/sync-config` prints
it for pasting into the workspace root `Cargo.toml`, and `rq/lints-check`
enforces it from then on:

```
lint-missing    canonical lint absent from the consumer manifest
lint-drift      present at a different level or priority
lints-opt-out   workspace member without `[lints] workspace = true`
```

Adding a lint fleet-wide means editing `lints.toml` here; every consumer's gate
then fails until it catches up. That is the intended pressure.

Two details that silently break the block if you get them wrong:

- A lint **group** entry needs `priority = -1`, or the group re-enables every
  individual `allow` below it.
- `[workspace.lints]` does **nothing** until each member declares
  `[lints]` / `workspace = true`.

## Stance

Inherited from `go-quality`: enable the bug-catching groups, disable the
style-pedantry members, cherry-pick from `restriction`, never enable that group
wholesale. Concretely — clippy `all` + `pedantic` with exactly ten pedantic
opt-outs, plus 28 individually named lints (mostly `restriction`) covering panic
surface, silent failure, unsafe hygiene, numeric traps and lint-suppression
discipline; `nursery` off except `cognitive_complexity`. On the rustc side: 11
lints including `unsafe_code`, `missing_docs`, `unreachable_pub` and
`non_ascii_idents`, plus 3 rustdoc lints.

`unsafe_code = "warn"` is on fleet-wide. Crates that need unsafe opt out in
their own manifest with a reason, and the hygiene lints
(`undocumented_unsafe_blocks`, `multiple_unsafe_ops_per_block`) carry the weight
from there.

Complexity has no separate script: clippy's `cognitive_complexity` plus
`cognitive-complexity-threshold = 30` in `clippy.toml` is the cap, enforced by
the lint gate with no second compile and no extra tool.

## Machine-readable findings (`--format jsonl` + `rq/findings`)

Every emitter also speaks **agent**. `--format jsonl` writes one finding per
line on stdout (human status routed to stderr) in the shared fleet schema:

```json
{"tool":"clippy","rule":"clippy::unwrap_used","level":"warning","path":"crates/a/src/lib.rs","line":7,"col":5,"message":"used `unwrap()` on an `Option` value","fingerprint":"clippy::unwrap_used:crates/a/src/lib.rs:7"}
```

Fields: `tool, rule, level (error|warning|note), path, line, col?, message,
fingerprint`. `level:error` = gate-failing. Emitters: `clippy` (the big one —
every lint in `lints.toml` lands here), `ai-lint` (every smell = error),
`lints-check` (drift = error), `budget` (god files + duplicate deps = warning).
Text output is byte-identical without the flag.

The **`rq/findings`** preset aggregates everything into one
`.gate/findings.jsonl` (gitignored, truncated per run). It is a **pure
producer** — emitters never abort the sweep and it does not re-gate;
enforcement stays with `rq/ci`. Dedup across runs via each finding's
`fingerprint`.

```yaml
findings: rq/findings   # -> .gate/findings.jsonl
```

Not for the local fast path: `clippy-findings.sh` busts the clippy cache
(`cargo clean -p` per workspace package) because **a warm clippy run reports
nothing at all**, and a gate step that silently reports nothing is worse than
no gate step.

## Knobs

| Var | Default | Meaning |
|---|---|---|
| `PKG_ARGS` | `--workspace` | Package selector passed to cargo |
| `FEATURE_ARGS` | `--all-features` | Feature selector — set `""` for mutually exclusive features |
| `CAP_LOC` | `500` | God-file soft cap, non-test `.rs` |

## Reconciliation notes (what stayed out, and why)

- **`cargo-audit`** — subsumed by `cargo deny check advisories`. One tool, one
  config file, one thing to keep current.
- **`cargo-udeps`** — needs nightly. `cargo-machete` is stable and catches the
  same class.
- **dupl / clone detection** — no credible Rust implementation exists. Nothing
  to wire; the god-file cap is the only structural proxy we trust.
- **arch-snapshot** — Go's package graph has no clean Rust analogue worth a new
  dependency. The one signal that carries, duplicate dependency versions, is
  folded into `budget-status.sh`.
- **structure-ratchet, SARIF** — deferred. The budget emitters are already
  shaped for the ratchet to drop in unchanged; `clippy-sarif` exists upstream
  for the SARIF leg.
- **Project-specific budgets and CI stages** — layered by each consumer after
  this gate, not here.

## Consuming this module

```yaml
vars: { PKG_ARGS: "--workspace", FEATURE_ARGS: "--all-features" }
modules:
  rq:
    source: "alehatsman/rust-quality@v0.1.0"
    props:
      pkg_args: "{{ PKG_ARGS }}"      # only exports that declare it receive it
      feature_args: "{{ FEATURE_ARGS }}"

tasks:
  fmt:     rq/fmt
  lint:    rq/lint
  test:    rq/test
  deny:    rq/deny
  ci:      rq/ci
  ci-fast: rq/ci-fast
  # budget-status / ai-lint / lints-check / tools declare neither prop —
  # the defaults are filtered out, so these wrappers work too:
  budget-status: rq/budget-status
  lints-check:   rq/lints-check
  findings:      rq/findings
```

Out-of-band presets — too slow or too project-specific for the push path — are
wired into a nightly or release task instead: `rq/cov`, `rq/semver`,
`rq/features`, `rq/miri`.

## First-time setup in a consumer repo

```
mooncake task tools          # rq/tools       — install the toolchain
mooncake task sync-config    # rq/sync-config — drop the configs, print the lint block
# paste the printed block into the workspace root Cargo.toml
# add `[lints]` / `workspace = true` to every member crate
mooncake task lints-check    # rq/lints-check — confirm it took
mooncake task ci             # rq/ci          — full gate
```
