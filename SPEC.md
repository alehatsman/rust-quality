# rust-quality — SPEC

v2, 2026-09-08. Decisions and evidence. The README describes what exists; this
records why, and what was measured to justify it.

## Goal

One canonical source for Rust lint policy, the quality gate, and the
agent-facing guide, consumed as a mooncake module.

## The governing decision

**Ship config, not command wrappers.**

Cargo reads `Cargo.toml`, `clippy.toml`, `rustfmt.toml`, `deny.toml` and
`.cargo/config.toml` natively. Anything built on top of it that merely restates
a cargo invocation is a file to maintain with nothing inside it. Consequences,
in order of leverage:

1. Anything that is one cargo invocation is a **cargo alias** shipped in
   `.cargo/config.toml`. Works with no mooncake at all.
2. A preset exists only for multi-step fail-fast ordering, or for copying
   config into a consumer.
3. JSON lives at **one** edge (`findings.sh`). `gate.sh` renders the same
   checks for humans from the same functions in `lib.sh` — define once, render
   twice.
4. Checks clippy already performs are not written a second time.
5. The gate runs no step whose work another step already did: clippy and the
   test profile both compile everything, so there is no separate build step.

## Lints deliberately excluded

`restriction` is cherry-picked, and overlapping members are left out so one
defect produces one finding. Each exclusion was probed against clippy 1.96 with
the canonical block applied, not assumed:

| Probe | Lints that fire | Therefore excluded |
|---|---|---|
| `*v.get(0).unwrap()` in a `-> Result` fn | `get_first`, `get_unwrap`, `unwrap_used` | `get_unwrap`, `unwrap_in_result` — subsets of `unwrap_used` |
| `panic!()` in a `-> Result` fn | `panic`, `panic_in_result_fn` | `panic_in_result_fn` — subset of `panic` |
| `x == 1.0` | `float_cmp` (pedantic) | `float_cmp_const` |
| `todo!()`, `unimplemented!()`, `unreachable!()` | `clippy::todo`, `::unimplemented`, `::unreachable` | any grep-based stub rule — clippy owns this |

Excluded as near-inert: `lossy_float_literal`, `unnecessary_safety_comment`,
`unnecessary_safety_doc`, `tests_outside_test_module`. Excluded as
false-positive-prone: `unreachable` — `unreachable!()` is correct in match arms
the compiler cannot prove exhaustive.

`nursery` is off as a group; `cognitive_complexity` is taken individually,
which makes clippy the single source for complexity: no second tool, no second
compile.

## Interfaces

Env: `PKG_ARGS` (`--workspace`), `FEATURE_ARGS` (`--all-features`), `CAP_LOC`
(`500`).

`lib.sh` records — the internal contract, format-free:

```
rule<TAB>level<TAB>path<TAB>line<TAB>message
```

Finding schema on the wire:

```json
{"tool":..,"rule":..,"level":"error|warning|note","path":..,"line":N,"col":N?,
 "message":..,"fingerprint":"rule:path:line"}
```

Exports: `ci`, `ci-fast`, `tools`, `sync-config`, `lints-check`, `findings`.

## Edge cases

- `--all-features` cannot build mutually exclusive features → `FEATURE_ARGS=""`.
- `[workspace.lints]` cannot be file-copied; cargo has no manifest include.
  `lints-check.sh` enforces instead of mutating.
- A lint group entry without `priority = -1` re-enables every `allow` below it.
- Members must declare `[lints] workspace = true` or the block applies to
  nothing.
- nextest never runs doctests; `cargo test --doc` hard-errors with no lib
  target, so `cargo metadata` is consulted first.
- `grep` exits 1 on no match, which is the normal case for every ai-lint rule.
  `lib.sh` runs inside a process substitution under `set -euo pipefail`, so
  every check pipeline ends in `|| true` or the first non-match kills the
  subshell and every later rule reports clean.
- `fast` only sees a staged diff, so `full` re-runs ai-lint over tracked files;
  otherwise `--no-verify`, amend, rebase and merge all bypass the only
  error-level rules there are.
- A workspace that does not compile must not read as a clean one: hard rustc
  errors carry no lint code, so `findings.sh` filters on the primary span and
  emits cargo's non-zero exit as its own `build-failed` record.
- A warm `cargo clippy` prints nothing — `findings.sh` runs `cargo clean -p` on
  workspace packages only, keeping deps warm.
- `imports_granularity` / `group_imports` are nightly-only rustfmt. Kept out.
- No git repo, no staged files, no lockfile → clean skip or a specific remedy,
  never a stack trace.

## Validation — actually run, 2026-09-08

Toolchain: cargo/clippy/rustfmt **1.96.0** (latest stable 1.98.1; nothing here
depends on anything newer, and 1.96 is the safe intersection for lint names).

- `shellcheck -x` + `bash -n` clean on all 5 scripts.
- **lints.toml parsed by real clippy — no `unknown lint`.** Negative control:
  injecting `no_such_lint_xyz` does produce `E0602`, so the check has teeth.
- **rustfmt.toml accepted with zero warnings.** Negative control: a bogus key
  warns, and `imports_granularity` warns "unstable features are only available
  in nightly" — the documented trap, reproduced.
- **Cargo aliases work**: `cargo lint` and `cargo docs` run in a fixture with
  only `.cargo/config.toml` present.
- **Fast gate green** on a clean fixture; **exits 1** on a dirty one. Asserted,
  not assumed — it guards a specific invariant: `render` must never be called
  through a pipe. A pipeline subshell discards its `FAILED=1`, and the gate
  would then exit 0 while printing error-level findings. Process substitution
  keeps it in the caller's shell.
- **Full gate** steps 1–4 green; step 5 hard-fails with an install hint because
  cargo-deny is absent here.
- **`full` catches residue `fast` cannot see.** On a fixture whose agent residue
  is committed rather than staged, `full` exits 0 without the ai-lint step and 1
  with it. The dirty-fixture assertion above passed with the ai-lint pipelines
  unguarded only because that fixture was a single file matching all three
  rules — no rule ever missed, so nothing ever exited 1. A two-file fixture
  where each file matches a different rule produces 0 records unguarded and 3
  guarded, and `god_files` filtering every path likewise ate `dup_deps`.
- **findings.sh on a non-building workspace** emits the code-less rustc
  diagnostics plus a `build-failed` record, where it previously wrote an empty
  file and reported `0 total, 0 error(s)`.
- **findings.sh**: 6 findings from all four sources (clippy, rq, lints-check),
  every line valid JSON, every line schema-conformant, 6/6 unique fingerprints.
- **lints-check** verified on four states: clean, missing lint, drifted level,
  member not opted in.
- **Missing vs stale lockfile** produce different, correct remedies — found by
  running the gate, not by reading it.
- 7 preset YAML files parse; every export resolves; no orphans.

## Known gaps

- **`deny.toml` is unvalidated.** cargo-deny is not installed here. Written to
  the documented v2 schema; run `cargo deny check` once after `rq/tools`.
- **Presets are not machine-validated.** `mooncake validate -c <component>`
  parses a component as a playbook and reports a false `unknown field name` —
  it does the same to every module's components, so this is a mooncake gap
  (alehatsman/mooncake#54), not a defect here.
- **No real consumer yet.** The first will shake out the `FEATURE_ARGS` default
  and the cargo-deny license allow-list.
