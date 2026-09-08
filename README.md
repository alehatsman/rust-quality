# rust-quality

Shared Rust quality gate for the fleet — the canonical lint block, the
clippy/rustfmt/cargo-deny config, cargo aliases, a two-mode gate, and the
agent-facing guide. Consumed as a [mooncake](https://github.com/alehatsman/mooncake)
module.

- [docs/RUST.md](docs/RUST.md) — how to write it. Rules, gate markers, the 2026 trap list, a review checklist.
- [docs/STACK.md](docs/STACK.md) — what to reach for. De-facto crate picks with versions and deviation triggers.

Go sibling: [go-quality](https://github.com/alehatsman/go-quality). Same finding
schema, different shape — see [Why this is not a port](#why-this-is-not-a-port).

## What's here

```
lints.toml       canonical [workspace.lints] — the single source of truth
clippy.toml      lint tuning: test exemptions, thresholds, doc idents
rustfmt.toml     formatting, stable options only
deny.toml        advisories + licenses + bans + sources
aliases.toml     cargo aliases + RUSTDOCFLAGS -> the consumer's .cargo/config.toml
scripts/
  lib.sh         the checks cargo does not do, defined once
  gate.sh        fast | full
  findings.sh    JSONL for agents — the only thing here that speaks JSON
  lints-check.sh lint-block drift (cargo cannot include manifests)
  tools.sh       install | check
docs/            the guide
```

Six exports: `ci`, `ci-fast`, `tools`, `sync-config`, `lints-check`, `findings`.

## Why this is not a port

go-quality has a preset per stage because **Go's toolchain is many binaries** —
gofmt, go vet, golangci-lint, govulncheck, gocyclo, goda, dupl, deadcode. Each
needs its own invocation, its own flags, its own wrapper.

Rust's toolchain is **one binary with subcommands, configured by files cargo
reads natively**. That inverts the design:

| | go-quality | rust-quality |
|---|---|---|
| Policy lives in | script flags | `Cargo.toml`, `clippy.toml`, `deny.toml` |
| One-command stages | a preset each | a **cargo alias** (`cargo lint`, `cargo t`) |
| Complexity cap | `gocyclo` + a budget script | `clippy::cognitive_complexity` + a threshold |
| Stub detection | `ai-lint` grep | `clippy::todo` / `unimplemented` |

The first cut of this repo mirrored go-quality file-for-file and measured badly:
**17 of 21 presets carried one line of payload**, `ai-lint` was 18 lines of rules
under 142 lines of scaffolding, four scripts each reimplemented the same JSON
emitter, and one `.get(0).unwrap()` tripped three overlapping lints. Rebuilt on
Rust's own grain:

| | before | after |
|---|---|---|
| presets | 21 + index | **6** + index |
| preset YAML | 486 lines | **145** |
| scripts | 8 | **5** |
| script lines | 745 | **509** |
| script code (non-comment) | 475 | **342** |
| clippy lint entries | 40 | **31** |

Nothing enforced was lost. What went was wrapping.

## Aliases before presets

`rq/sync-config` installs `.cargo/config.toml`, so the common commands work with
no mooncake, no module fetch and no YAML — in a terminal, in CI, in an editor:

```
cargo lint       # clippy, all targets, all features, -D warnings
cargo t          # nextest
cargo doctest    # nextest never runs doctests — a separate alias, not a silent gap
cargo docs       # rustdoc; RUSTDOCFLAGS=-D warnings comes from [env]
```

A preset earns its place only when it does something an alias cannot: a
multi-step gate with fail-fast ordering, or copying files into a consumer repo.

## The gate

`gate.sh fast` — pre-commit. Lockfile drift, `cargo fmt --check`, clippy,
ai-lint on staged files, soft caps. No extra tools, no network.

`gate.sh full` — pre-push. fmt, clippy, test + doctests, rustdoc, cargo-deny,
cargo-machete, lint-block drift, soft caps.

Four things the gate exists to get right, all of which pass silently otherwise:

- **nextest never runs doctests.** They need a second invocation.
- **`cargo test --doc` hard-errors** on a workspace with no lib target, so it is
  asked for only when `cargo metadata` reports one.
- **A separate `cargo build` step is a wasted full compile** — clippy and the
  test profile already build everything. Dropped.
- **`[workspace.lints]` does nothing** until every member opts in.

## The lint block is not a file copy

`clippy.toml`, `rustfmt.toml`, `deny.toml` and `.cargo/config.toml` are copied
in by `rq/sync-config`. The lint levels cannot be: **cargo has no include
mechanism for manifests**. So `lints.toml` is the canonical text, sync-config
prints it, and `rq/lints-check` enforces it:

```
lint-missing    canonical lint absent from the consumer manifest
lint-drift      present at a different level or priority
lints-opt-out   workspace member without `[lints] workspace = true`
```

Two ways to get it silently wrong:

- A lint **group** entry needs `priority = -1`, or the group re-enables every
  individual `allow` below it.
- `[workspace.lints]` applies to nothing until each member declares
  `[lints]` / `workspace = true`.

## Stance

clippy `all` + `pedantic` with ten pedantic opt-outs, plus 31 individually named
lints covering panic surface, silent failure, unsafe hygiene and
lint-suppression discipline. `nursery` off except `cognitive_complexity`, which
is the complexity cap — no second tool, no second compile.

`unsafe_code = "warn"` fleet-wide; crates that need it opt out in their own
manifest with a reason, and `undocumented_unsafe_blocks` carries the weight
from there.

Lints are cherry-picked, never taken as a group from `restriction` — and
overlaps are cut. `get_unwrap`, `unwrap_in_result` and `panic_in_result_fn` all
fire on code `unwrap_used`/`panic` already flag; `float_cmp_const` is covered by
pedantic's `float_cmp`. One finding per defect.

## Findings for agents

`rq/findings` writes `.gate/findings.jsonl` — clippy diagnostics, ai-lint,
lint-block drift and soft caps in the schema shared with go-quality:

```json
{"tool":"clippy","rule":"clippy::indexing_slicing","level":"warning","path":"crates/a/src/lib.rs","line":25,"col":5,"message":"indexing may panic","fingerprint":"clippy::indexing_slicing:crates/a/src/lib.rs:25"}
```

`level:error` is gate-failing. A pure producer: it never re-gates and never
aborts on a finding. Dedup across runs via `fingerprint`.

Only `findings.sh` speaks JSON. `gate.sh` renders the same checks for humans
from the same functions in `lib.sh` — the format lives at the edge.

Not for the pre-commit path: the clippy pass runs `cargo clean -p` on the
workspace packages first, because **a warm `cargo clippy` prints nothing at
all**, and a check that silently reports nothing is worse than no check.

## Knobs

| Var | Default | Meaning |
|---|---|---|
| `PKG_ARGS` | `--workspace` | Package selector passed to cargo |
| `FEATURE_ARGS` | `--all-features` | Set `""` for mutually exclusive features |
| `CAP_LOC` | `500` | God-file soft cap, non-test `.rs` |

## Consuming this module

```yaml
modules:
  rq:
    source: "github.com/alehatsman/rust-quality@v0.2.0"
    props:
      feature_args: "{{ FEATURE_ARGS }}"

tasks:
  ci:      rq/ci
  ci-fast: rq/ci-fast
  findings: rq/findings
```

First-time setup:

```
mooncake task tools          # three tools + clippy/rustfmt components
mooncake task sync-config    # configs + cargo aliases; prints the lint block
# paste the block into the workspace root Cargo.toml
# add `[lints]` / `workspace = true` to every member crate
mooncake task ci
```

## Not here, on purpose

- **`cargo build` / `check` / `doc` / `machete` presets** — one cargo call each.
  Aliases, or one line in your own `tasks.yml`.
- **cov / semver / features / miri presets** — the commands are in
  `tools.sh install` output. A preset that wraps one invocation you run twice a
  year is a file to maintain, not leverage.
- **cargo-audit** — `cargo deny check advisories` covers it.
- **cargo-udeps** — nightly. `cargo-machete` is stable.
- **dupl / clone detection** — no credible Rust implementation exists.
- **arch-snapshot** — Go's package graph has no Rust analogue worth a
  dependency. Duplicate dep versions, the one signal that carries, is in the
  soft caps.
- **structure-ratchet, SARIF** — deferred. `lib.sh` records are already the
  right shape for the ratchet; `clippy-sarif` exists upstream.
