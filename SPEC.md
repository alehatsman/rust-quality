# rust-quality — SPEC

v2, 2026-09-08. Decisions and evidence. The README describes what exists; this
records why, and what was measured to justify it.

## Goal

One canonical source for Rust lint policy, the quality gate, and the
agent-facing guide, consumed as a mooncake module.

## The governing decision

**Ship config, not command wrappers.**

go-quality is one preset per stage because Go's toolchain is eight binaries.
Rust's is one binary reading config files natively, so the same layout produces
wrappers with nothing inside them. Measured on v1, which was a direct port:

- **17 of 21 presets had exactly one line of payload** — 486 lines of YAML
  carrying ~40 lines of command.
- `ai-lint.sh`: **18 lines of rules, 142 lines of scaffolding**.
- Four scripts each reimplemented the JSONL emitter (8–15 lines apiece).
- A separate `cargo build --all-targets` step in the full gate was **a wasted
  full compile** — clippy and the test profile already build everything.

Consequences, in order of leverage:

1. Anything that is one cargo invocation becomes a **cargo alias** shipped in
   `.cargo/config.toml`. Works with no mooncake at all.
2. A preset exists only for multi-step fail-fast ordering, or for copying
   config into a consumer.
3. JSON lives at **one** edge (`findings.sh`). `gate.sh` renders the same
   checks for humans from the same functions in `lib.sh`.
4. Checks clippy already performs are deleted, not duplicated.

## Evidence for the lint cuts

Probe crate, clippy 1.96, canonical block applied:

| Probe | Lints fired | Conclusion |
|---|---|---|
| `*v.get(0).unwrap()` in a `-> Result` fn | `get_first`, `get_unwrap`, `unwrap_used` | `get_unwrap` and `unwrap_in_result` are subsets of `unwrap_used` — cut |
| `panic!()` in a `-> Result` fn | `panic`, `panic_in_result_fn` | subset of `panic` — cut |
| `x == 1.0` | `float_cmp` (from pedantic) | `float_cmp_const` redundant — cut |
| `todo!()`, `unimplemented!()`, `unreachable!()` | `clippy::todo`, `::unimplemented`, `::unreachable` | ai-lint's `stub-macro` rule was pure duplication — cut |

Also cut as near-inert: `lossy_float_literal`, `unnecessary_safety_comment`,
`unnecessary_safety_doc`, `tests_outside_test_module`, `unreachable` (legitimate
in match arms the compiler cannot prove exhaustive).

40 clippy entries → 31. Nothing enforced was lost; overlapping reports were.

## Interfaces

Env: `PKG_ARGS` (`--workspace`), `FEATURE_ARGS` (`--all-features`), `CAP_LOC`
(`500`).

`lib.sh` records — the internal contract, format-free:

```
rule<TAB>level<TAB>path<TAB>line<TAB>message
```

Finding schema on the wire, shared with go-quality:

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
- **Fast gate green** on a clean fixture; **exits 1** on a dirty one. This is a
  regression test, not a smoke test: `render` was originally called through a
  pipe, so its `FAILED=1` was discarded by the subshell and the gate would have
  exited 0 on error-level findings. Fixed with process substitution.
- **Full gate** steps 1–4 green; step 5 hard-fails with an install hint because
  cargo-deny is absent here.
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
  it does the same to go-quality's shipped components, so this is a mooncake
  gap (alehatsman/mooncake#54), not a defect here.
- **No real consumer yet.** The first will shake out the `FEATURE_ARGS` default
  and the cargo-deny license allow-list.
