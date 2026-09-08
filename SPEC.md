# rust-quality — SPEC

Status: v1 draft, 2026-09-08. Mirrors `go-quality` for Rust; not a blind port.

## Goal

One canonical source for Rust lint config, quality gates, and the agent-facing
Rust guide, consumed as a mooncake module by every Rust repo in the fleet.

Two deliverables, one repo:

1. **Gate module** — configs + scripts + mooncake presets. Machine-enforced.
2. **Guide** — `docs/RUST.md` (how to write it) and `docs/STACK.md` (what to
   reach for). Human/agent-read, not enforced.

## Scope

### In

- Shared configs: `lints.toml` (canonical `[workspace.lints]`), `clippy.toml`,
  `rustfmt.toml`, `deny.toml`.
- Gates: check, fmt, lint, test, build, doc, deny, machete, cov, semver,
  features, miri, ai-lint, budget, lints-check.
- Aggregate gates: `ci-fast` (pre-commit), `ci` (pre-push).
- JSONL findings stream (`.gate/findings.jsonl`) in go-quality's schema, with
  clippy's native `--message-format=json` folded in.
- Toolchain install/verify.
- Two guide docs.

### Out (deferred, with reasons)

- **structure-ratchet** — needs the budget metrics to settle first. The budget
  emitters are shaped so the ratchet drops in later unchanged.
- **SARIF** — leaf format change; `clippy-sarif` already exists upstream. v2.
- **dupl** — no credible Rust clone detector. Nothing to wire.
- **arch-snapshot** — Go's package graph has no clean Rust analogue worth the
  dependency. The one signal that carries (`cargo tree --duplicates`) is folded
  into `budget-status` instead.
- **cargo-audit** — subsumed by `cargo deny check advisories`. One tool, one
  config, fewer deps.
- **cargo-udeps** — needs nightly. `cargo-machete` is stable and good enough.

## Interfaces

### Env knobs (shared by all scripts)

| Var             | Default          | Meaning                                    |
|-----------------|------------------|--------------------------------------------|
| `PKG_ARGS`      | `--workspace`    | Package selector passed to cargo           |
| `FEATURE_ARGS`  | `--all-features` | Feature selector. Set `""` for exclusive features |
| `CAP_LOC`       | `500`            | God-file soft cap, non-test `.rs`          |
| `CAP_COGNITIVE` | `30`             | Cognitive-complexity soft cap (clippy)     |
| `GATE_DIR`      | `.gate`          | Findings artifact dir                      |

### Findings schema (identical to go-quality)

```json
{"tool":"…","rule":"…","level":"error|warning|note","path":"…","line":1,"col":1,
 "message":"…","fingerprint":"rule:path:line"}
```

`level:error` = gate-failing. stdout is pure JSONL under `--format jsonl`;
human status goes to stderr.

### mooncake exports (`rq/*`)

`default`/`ci`, `ci-fast`, `tools`, `sync-config`, `check`, `fmt`, `lint`,
`test`, `build`, `doc`, `deny`, `machete`, `cov`, `semver`, `features`, `miri`,
`ai-lint`, `budget-status`, `lints-check`, `findings`.

### Gate composition

`ci-fast` (pre-commit, cheap):
1. `cargo check` — type check, all targets
2. `Cargo.lock` drift (`--locked`)
3. `cargo fmt --check` on staged `.rs`
4. ai-lint on staged `.rs`
5. budget soft caps

`ci` (pre-push, first failure stops):
1. build `--locked`
2. test — nextest **plus** doctests (nextest does not run doctests)
3. `cargo fmt --check`, whole tree
4. clippy `-D warnings`
5. rustdoc `-D warnings`
6. `cargo deny check`
7. `cargo machete`
8. duplicate dep versions (informational)
9. budget soft caps

Opt-in / out of band: `cov`, `semver`, `features`, `miri`. Too slow or too
project-specific for the push path.

## Edge cases

- **`--all-features` breaks mutually-exclusive features.** Documented; override
  with `FEATURE_ARGS=""`.
- **`[workspace.lints]` cannot be file-copied.** Cargo has no include
  mechanism. `sync-config` copies the three real config files; `lints-check.sh`
  asserts the consumer's `Cargo.toml` carries the canonical lint keys and
  reports drift. Enforcement, not mutation.
- **Lint group + individual allow needs `priority`.** Group entries carry
  `priority = -1` or the allows are overridden.
- **Member crates must opt in** with `[lints] workspace = true`. lints-check
  verifies this too.
- **`imports_granularity` / `group_imports` are nightly-only rustfmt.** Not in
  `rustfmt.toml`. Documented as a trap.
- **No git repo / no staged files.** Scripts degrade to a clean skip, exit 0.
- **Missing tools.** `ci` treats them as fatal; individual presets say what to
  install.
- **`unsafe_code = "warn"`** by default; crates that need unsafe set it to
  `allow` locally with a reason and pick up `undocumented_unsafe_blocks`.

## Validation — what was actually run (2026-09-08)

Local toolchain: cargo/rustc/clippy/rustfmt **1.96.0**. Latest stable is 1.98.1;
nothing in the configs depends on anything newer, and every lint name was
checked against 1.96, which is the safe intersection.

Done:

- `shellcheck` + `bash -n` clean on all 8 scripts.
- **lints.toml parsed by real clippy.** A scratch workspace pastes the block into
  its manifest; `cargo clippy` reports **no `unknown lint`**. Negative control:
  injecting `no_such_lint_xyz` does produce `E0602`, so the check has teeth.
- **Individual lints confirmed firing**: `indexing_slicing`, `unwrap_used`,
  `clone_on_ref_ptr`, `allow_attributes`, `allow_attributes_without_reason`,
  `doc_markdown`.
- **rustfmt.toml accepted with zero warnings.** Negative control: adding
  `bogus_key_xyz` warns "Unknown configuration option", and adding
  `imports_granularity` warns "unstable features are only available in nightly"
  — the documented trap, reproduced.
- **`ci/fast.sh` green end to end** on a fixture workspace (all 5 steps).
- **`ci/full.sh` steps 1–5 green**; step 6 correctly hard-fails with the install
  hint because cargo-deny is absent on this machine.
- **All 4 emitters** produce schema-conformant JSONL with unique fingerprints;
  every line validated with `jq -e`; mixed error/warning stream verified.
- **`lints-check.sh`** verified on all four states: clean, missing lint, drifted
  level, member not opted in.
- **22 preset YAML files parse** (`yq -e`); every `index.yml` export resolves to
  a real file; no orphan presets.

Not done, and why:

- **`deny.toml` is unvalidated.** cargo-deny is not installed on this machine
  and installing it was out of scope. The schema is written against the
  documented v2 format; run `cargo deny check` once after `rq/tools` and expect
  to adjust `[advisories]` if the schema has moved.
- **Presets are not machine-validated.** `mooncake validate -c <component>`
  parses a component as a playbook and reports a false `unknown field \`name\``
  — it does the same for go-quality's shipped components, so this is a mooncake
  gap, not a defect here. Validation basis is YAML well-formedness plus
  structural parity with go-quality's working presets.
- **Not run against a real project.** No Rust repo in the fleet consumes this
  yet. First consumer will shake out the `FEATURE_ARGS` default and the
  cargo-deny license allow-list.
