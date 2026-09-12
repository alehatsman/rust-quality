# rust-quality — SPEC

v3, 2026-09-11. Decisions and evidence. The README describes what exists; this
records why, and what was measured to justify it.

## Goal

One canonical source for Rust lint policy, the quality gate, and the
agent-facing guide, consumed as a provision component set.

## The governing decision

**Ship config, not command wrappers.**

Cargo reads `Cargo.toml`, `clippy.toml`, `rustfmt.toml`, `deny.toml` and
`.cargo/config.toml` natively. Anything built on top of it that merely restates
a cargo invocation is a file to maintain with nothing inside it. Consequences,
in order of leverage:

1. Anything that is one cargo invocation is a **cargo alias** shipped in
   `.cargo/config.toml`. Works with no provision at all.
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
(`500`), `RQ_PYTHON` (unset — names the interpreter `lints-check` should use,
skipping the probe).

**Interpreter floor: bash 3.2, and a python found by capability.** The scripts
run under macOS's `/bin/bash` 3.2 — no `mapfile`, no associative arrays, no
namerefs — because the manifests invoke them as a bare `bash` and the shebang
never gets a say. `lints-check` needs a TOML parser and asks each candidate
whether it has one rather than trusting the name `python3`; `tomllib` (3.11+)
and the `tomli` backport are both accepted.

`lib.sh` records — the internal contract, format-free:

```
rule<TAB>level<TAB>path<TAB>line<TAB>message
```

Finding schema on the wire. `fingerprint` carries a trailing `key` only where
one location can hold more than one finding of the same rule — a missing lint
has no line to point at, so every `lint-missing` in a run would otherwise
collide on `:1` and dedup would keep exactly one of them:

```json
{"tool":..,"rule":..,"level":"error|warning|note","path":..,"line":N,"col":N?,
 "message":..,"fingerprint":"rule:path:line[:key]"}
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
- **`python3` on PATH is not the python you want.** macOS ships 3.9 at
  `/usr/bin/python3`, and `/usr/libexec/path_helper` — run from `/etc/zprofile`
  on every login shell — rebuilds PATH with `/etc/paths` ahead of everything,
  so `/usr/bin` outranks Homebrew whatever order it inherits. Seeding it with
  `/opt/homebrew/bin:/usr/bin` hands back `/usr/bin` first, and
  `/etc/paths.d/homebrew` cannot beat it either. `py_toml` therefore probes for
  the capability and falls back to absolute prefixes for a PATH stripped past
  the point where any name resolves. No parser anywhere → one actionable
  message and exit 2, never a `ModuleNotFoundError`.
- **A `lints-check` that could not run must not read as one that found
  nothing.** `findings.sh` never aborts, so it turns exit 2 into a
  `no-toml-parser` record — same reasoning as `build-failed`.

## Validation — actually run, 2026-09-12

Portability pass, on macOS 15 aarch64. Every run below used `/bin/bash` 3.2.57
explicitly and `env -i` with a PATH holding no Homebrew entry, which is what a
non-interactive shell on this fleet's Macs actually gets.

- **`bash -n` clean on all 5 scripts under bash 3.2**, and `shellcheck -x`
  clean. `mapfile` is a builtin rather than syntax, so `bash -n` never caught
  it — only a run did.
- **`gate.sh fast` green, all 5 steps**, step 4 included. It previously died at
  step 4 on `mapfile: command not found`.
- **`findings.sh` green**, 6 findings, valid JSONL. Second `mapfile` site.
- **The read loop that replaced `mapfile` keeps what `mapfile -t` kept**: a
  path with a space and a non-ASCII path both survive intact; blank lines drop.
- **`lints-check.sh` green with python 3.9 first on PATH** — the probe rejected
  `/usr/bin/python3` (3.9.6) and selected `/opt/homebrew/bin/python3` (3.14.7)
  by absolute path, with no Homebrew entry on PATH at all.
- **The `tomli` backport path runs end to end** on an interpreter that
  genuinely has no `tomllib`: 3.9.6 with `tomli` resolvable, real parse, exit 0.
- **Negative control** — every candidate removed so the probe cannot be
  satisfied: 4 lines naming the floor and the `RQ_PYTHON` escape hatch, exit 2.
  No traceback.

## Validation — actually run, 2026-09-11

Toolchain: cargo/clippy/rustfmt **1.98.1**, cargo-deny, cargo-nextest and
cargo-machete all present. Every claim below is a run, not a reading.

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
- **Full gate** green end to end, all 9 steps, cargo-deny included.
- **`deny.toml` validated against real cargo-deny.** A two-crate private
  workspace was `licenses FAILED` on `error[unlicensed]` before
  `private.ignore`; the fleet allow-list also emitted one
  `license-not-encountered` per unmet entry — 5 on the provision repo, now 0.
- **nextest exits 1 on a workspace with no tests** (`--no-tests` defaults to
  `fail` since 0.9.85). A zero-test lib crate stopped the full gate at step 3;
  with `--no-tests=warn` it reaches step 4.
- **`god_files` loses paths.** A path with a space was truncated at the space
  and a non-ASCII path was C-quoted into a name `wc` cannot open, so it was
  skipped entirely. Both now report paths that resolve on disk.
- **`lints-check` could not see implicit members.** A crate reached only as a
  path dependency is a real member per `cargo metadata`, inherits nothing, and
  the `members` glob reported the workspace clean. Asking cargo catches it; the
  glob fallback announces itself.
- **`sync-config` destroyed a consumer's `.cargo/config.toml`.** `[build]
  rustflags` was replaced by four aliases. `creates` gates the write; verified
  with `provision apply` on both an absent and a present file.
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
- **Five of six components pass `provision validate --strict`.** `tools.yml`
  does not, and should not: `--strict` demands an idempotency gate on every
  `shell` step, and the install step cannot honestly claim one — it changes real
  state and cannot say in advance whether it will. A consumer that wants the
  step gated adds its own `creates:` at the `use` site, which is what the
  provision repo does; a `use` site cannot reach inside to remove one.
- **Both new lints measured against the one real consumer before landing**:
  `exit` and `infinite_loop` are 0 hits on the provision repo.

## Known gaps

- **The toolchain floor is a claim, not a measurement.** The block is validated
  on 1.98.1; the oldest clippy that accepts every lint in it has not been
  established, because that needs old toolchains installed. An unknown lint is
  `error[E0602]` and `lints-check` cannot see it coming.
- **Two lints deferred with a price attached.** `unused_trait_names` is 39 hits
  on the provision repo and `mod_module_files` is 4 file renames. Both enforce
  rules docs/RUST.md already states; both are a consumer refactor, not a config
  line.
- ~~**`scripts/lints-check.sh` needs python3 ≥ 3.11** for `tomllib`, and says so
  only by traceback.~~ **Closed 2026-09-12.** It still needs a TOML parser —
  that part was never the gap. The gap was trusting the name `python3` to be
  one, on the one platform where it reliably is not, and then reporting it as a
  traceback. It now probes by capability and says what to install.
- **Outside a git repo the scripts exit 1 on `cd ""`**, after a bare `git
  fatal:` and a bash `cd: null directory`. Correct exit code, wrong message —
  the edge-case list above promises a remedy, not this.
