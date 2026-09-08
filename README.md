# rust-quality

Shared Rust quality gate for the fleet — the canonical lint block, the
clippy/rustfmt/cargo-deny config, cargo aliases, a two-mode gate, and the
agent-facing guide. Consumed by
[provision](https://github.com/alehatsman/provision).

- [docs/RUST.md](docs/RUST.md) — how to write it. Rules, gate markers, the 2026 trap list, a review checklist.
- [docs/STACK.md](docs/STACK.md) — what to reach for. De-facto crate picks with versions and deviation triggers.

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

Six presets. Anything that is a single cargo invocation is a cargo alias (see
`aliases.toml`), not a preset; presets exist only for multi-step gates with
fail-fast ordering, and for getting config into a consumer repo.

| File | What it does |
|---|---|
| `ci.yml` | full pre-push gate — fmt, clippy, test + doctests, rustdoc, cargo-deny, cargo-machete, lint drift, soft caps |
| `fast.yml` | pre-commit gate — lockfile drift, fmt, clippy, ai-lint on staged files, soft caps. No extra tools, no network |
| `tools.yml` | install + verify cargo-nextest, cargo-deny, cargo-machete and the clippy/rustfmt components |
| `sync-config.yml` | config into the consumer repo, and print the lint block |
| `lints-check.yml` | lint-block drift — the one thing cargo cannot do for us |
| `findings.yml` | every finding as JSONL for agents → `.gate/findings.jsonl` |

## How a consumer reaches it

A preset is a provision component, `use`d by file path from a checkout the
consumer's own plan clones and pins:

```yaml
steps:
  - name: full gate
    use: ~/.cache/provision/tools/rust-quality/ci.yml
```

```
$ provision list ~/.cache/provision/tools/rust-quality/
$ provision apply tasks/ci.yml
```

Nothing fetches at gate time. The checkout is a step in the consumer's plan,
`creates`-gated like any other, so a bump is a one-line version change and
offline works.

Inside a preset, `{{ component_dir }}` is this checkout's own directory, which
is how a step reaches `scripts/` and how `rq/sync-config` reads the config it
copies. A relative `path:` is not resolved against anything and so lands in the
directory provision was invoked from, which is the consumer repo. Read from
here, write over there, with no argument saying where "there" is.

**`dir`** names the crate. Every preset that runs cargo takes it, defaulting to
`"."`, so a single-crate repo passes nothing. A repo whose crates are not one
workspace passes each in turn:

```yaml
steps:
  - name: daemon
    use: ~/.cache/provision/tools/rust-quality/ci.yml
    props: { dir: daemon }
  - name: cli
    use: ~/.cache/provision/tools/rust-quality/ci.yml
    props: { dir: cli }
```

Whether those crates should be one workspace instead is that repo's business,
not the gate's.

The presets carry no `name:` or `version:` root key and there is no exports
table: the tag is the version, and provision lists a directory by each file's
`description:`.

## Design

Cargo is the interface. It reads `Cargo.toml`, `clippy.toml`, `rustfmt.toml`,
`deny.toml` and `.cargo/config.toml` without being asked, so **this repo ships
config, not command wrappers**. Three rules follow.

**One cargo invocation is an alias, not a preset.** `rq/sync-config` installs
`.cargo/config.toml`, so the everyday commands work in a terminal, in CI and in
an editor with no provision and no YAML:

```
cargo lint       # clippy, all targets, all features, -D warnings
cargo t          # nextest
cargo doctest    # nextest never runs doctests — a separate alias, not a silent gap
cargo docs       # rustdoc; RUSTDOCFLAGS=-D warnings comes from [env]
```

**A preset exists only for what an alias cannot do** — a multi-step gate with
fail-fast ordering, or getting config into a consumer repo. Six of them.

**A check clippy already performs is not written twice.** Complexity is
`clippy::cognitive_complexity` with a threshold, not a second tool. Stub
detection is `clippy::todo` / `unimplemented`, not a grep. Overlapping lints are
cut so one defect produces one finding.

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
lint-block drift and soft caps in the shared fleet schema:

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

## Knobs, from a call site

`PKG_ARGS`, `FEATURE_ARGS` and `CAP_LOC` above are what `scripts/` reads. From
provision they are props, and `dir` names the crate:

```yaml
steps:
  - name: full gate
    use: ~/.cache/provision/tools/rust-quality/ci.yml
    props: { dir: daemon, feature_args: "" }
```

First-time setup in a consumer repo:

```
provision apply tasks/tools.yml         # three tools + clippy/rustfmt components
provision apply tasks/sync-config.yml   # config + cargo aliases; prints the lint block
# paste the block into the workspace root Cargo.toml
# add `[lints]` / `workspace = true` to every member crate
provision apply tasks/ci.yml
```

`tasks/` in the consumer is one file per preset, each a `description:` and one
`use:` line. provision's own repo is the worked example.

## Not here, on purpose

- **`cargo build` / `check` / `doc` / `machete` presets** — one cargo call each.
  Aliases, or one line in your own `tasks.yml`.
- **cov / semver / features / miri presets** — the commands are in
  `tools.sh install` output. A preset that wraps one invocation you run twice a
  year is a file to maintain, not leverage.
- **cargo-audit** — `cargo deny check advisories` covers it.
- **cargo-udeps** — nightly. `cargo-machete` is stable.
- **dupl / clone detection** — no credible Rust implementation exists.
- **A dependency-graph snapshot** — not worth a new tool. The one signal worth
  having, duplicate dependency versions, is in the soft caps.
- **structure-ratchet, SARIF** — deferred. `lib.sh` records are already the
  right shape for the ratchet; `clippy-sarif` exists upstream.
