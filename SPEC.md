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
(`500`), `CAP_COMMENT_RUN` (`15`), `CAP_COMMENT_RATIO` (`40`), `RQ_PYTHON`
(unset — names the interpreter `lints-check` should use, skipping the probe).

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

## The comment budget

`missing_docs` and `rustdoc -D warnings` push doc comments up. Nothing pushed
non-doc `//` down, and the asymmetry shows: an agent that cannot delete is
rewarded for narrating, and the narration accretes where no lint looks. clippy
has no comment-volume opinion and there is no credible Rust tool for one, so
this is the second thing `lib.sh` owns outright — three rules, one awk pass per
file, no new tool and no second compile.

| Rule | Level | Fires on |
|---|---|---|
| `commented-out-code` | error | a non-doc `//` line that is Rust, not prose |
| `comment-block` | warning | a run of `CAP_COMMENT_RUN` consecutive non-doc `//` lines |
| `comment-ratio` | warning | non-doc `//` over `CAP_COMMENT_RATIO`% of code lines |

**Only `commented-out-code` is an error, and only because it has a unique
property: it is never right.** Dead code in a comment is a worse lie than dead
code, because the compiler cannot even tell you it rotted. The other two are
judgement — a 40-line comment earning its keep is the house style in this very
repo — so they are soft caps alongside `god-file`, reported and never fatal.

**The error rule is matched on shape, not on keywords.** A keyword alone is
prose (`// let the caller decide`, `// use the first one that works`), so every
pattern pairs a declaration head with a code terminator: `let` needs an `=` and
a `;`, `fn` needs a `{`, an attribute must be the entire line. The cost of a
false positive here is a failed gate on correct source, which is why the six
patterns are narrow and a bare call statement — `// foo(bar);`, indistinguish-
able from the C that gets quoted in a `// SAFETY:` block — is deliberately not
one of them.

Doc comments are outside all three rules. `///` and `//!` are governed by
`missing_docs`, `rustdoc` and docs/RUST.md rule 60; counting them here would
mean two gates pulling the same line in opposite directions.

## god-file counts code, not bytes

`CAP_LOC` was `wc -l`, so a 74-line comment block spent 74 lines of a 500-line
budget and the one check meant to bound file size was partly measuring prose.
It now counts lines that are neither blank nor comment, which is the thing the
cap was always about. `comment-ratio` is what bounds the other half, and the
two together say what one `wc -l` could not: this file is too big, versus this
file is mostly talking.

## too_many_lines, un-orphaned

`lints.toml` allowed `clippy::too_many_lines` and credited the LOC ratchet to
`scripts/budget-status.sh`; `clippy.toml` named the same script as the twin of
its thresholds. **That script does not exist and is in no git history here.**
The delegation was to nothing, so function length was enforced by nothing — the
only surviving cap was `god-file`, at file scope, 500 lines away from the
problem. The lint is now `warn` with `too-many-lines-threshold = 200`, and both
comments that pointed at the ghost are gone.

200 is the measured number, not a round one. Every clippy `warn` is fatal under
the gate's `-D warnings`, so the threshold decides how much of the fleet is
red on the day it lands: 150 fails 10 sites across 5 crates, 200 fails 4 across
4, and 250 fails none because the longest function anywhere is 242 lines. 250
would have been a ceiling that never touches anything; 200 puts pressure on
exactly the four functions that are outliers against their own fleet.

## `.cargo/config.toml` drifts and nothing noticed

`sync-config` gates that file on `creates:` — correct, because it is where a
consumer keeps its own `[build] rustflags` and `[target.*] linker`, and writing
ours over that is data loss, not a sync. But `creates:` is write-once: the file
is installed on day one and never reconciled again, and the preset's `unless:`
branch prints the aliases to merge by hand, which is advice, not a gate.

Measured across the fleet before this change: four of five consumers that had
the file were still on a copy predating `--no-tests=warn`, and three still
carried the name of a tool that no longer exists. Nobody merged the printout,
and nothing ever said so.

So the same answer as the lint block, for the same reason: **where we must not
mutate, we enforce.** `alias_drift` compares each `name = "value"` under
`[alias]` in the consumer's file against `aliases.toml` and reports what is
missing or different, as a warning — the consumer's file stays the consumer's.
It is a line match, not a TOML parse: the keys are ours, they are written on
one line, and a parser here would buy nothing a literal compare does not
already get right.

## Edge cases

- `--all-features` cannot build mutually exclusive features → `FEATURE_ARGS=""`.
- `[workspace.lints]` cannot be file-copied; cargo has no manifest include.
  `lints-check.sh` enforces instead of mutating.
- A lint group entry without `priority = -1` re-enables every `allow` below it.
- Members must declare `[lints] workspace = true` or the block applies to
  nothing.
- nextest never runs doctests; `cargo test --doc` hard-errors with no lib
  target, so `cargo metadata` is consulted first.
- A comment run that reaches EOF still has to be emitted: the run is flushed
  when a non-comment line ends it, and a file ending in its own banner has no
  such line. Flushed again in `END`.
- `comment-ratio` needs a floor as well as a cap. A 6-line stub with 4 lines of
  header is 66% and says nothing; the rule is silent under 50 code lines.
- A run of `//` inside a raw string or a `r#".."#` block is not a comment. awk
  cannot see that without lexing Rust, so the rules accept it — the cost is a
  warning on a file embedding commented source as data, which is also a file
  worth looking at.
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

## Validation — actually run, 2026-10-19

Toolchain: cargo/clippy 1.98.1, shellcheck, cargo-deny, cargo-nextest,
cargo-machete present. Fleet measured across 7 crates in 6 repos, 293 `.rs`
files.

- `shellcheck -x` + `bash -n` clean on all 5 scripts. The one new suppression
  is `SC2016` in `god_files`, and it is a shellcheck limitation, not a bug:
  shellcheck recognises an awk program when `awk` is the command and not when
  it is an `xargs` argument, so it reads awk's `$0` as a failed shell
  expansion. The baseline piped into `awk`; counting per file needs `FILENAME`,
  which needs the names as arguments.
- **`commented-out-code` fires 6/6 on real dead code and 0/5 on the traps.**
  Positive: a commented `let`-with-initialiser, `fn`-with-brace, `pub struct`,
  `use` path, `#[derive]` and `const`. Negative, all silent: `/// let doc = 1;`
  (a doc comment), `// let the caller decide what to do;` and `// use the first
  one that works;` (prose opening with a keyword), `// tty_vhangup_session
  (tty);` (quoted C in a SAFETY block), and `// #[allow] (not #[expect]) plus
  its own #[expect(allow_attributes)]` (prose *about* attributes).
- **The error rule is 0 hits across the whole fleet**, which is the result that
  justified landing it at error: it costs nobody a refactor and nothing has to
  be cleaned before it is switched on. A broad probe run first — bare call
  statements, lone braces, `.method();` — found 8 hits, and all 8 were prose
  fragments or deliberate XNU kernel-source citations. There is no
  commented-out Rust in this fleet. The rule is a ratchet against a spiral,
  not a cleanup of one.
- **`comment-block` boundary is exact**: 14 consecutive lines silent, 15 fires.
  A run terminated by EOF is reported — a 20-line trailing banner with no
  following code produced its record from the `END` flush, which the
  during-the-loop flush alone would have dropped.
- **`comment-ratio` floor works**: a 30-comment/60-code fixture reports 50%; a
  6-line stub under a 4-line header, which is 66%, stays silent.
- **Fleet totals at the chosen caps**: 27 `comment-block`, 1 `comment-ratio`, 0
  `commented-out-code`. `CAP_COMMENT_RUN = 15` was picked off the measured
  distribution, not guessed — of 3097 non-doc comment runs, 469 reach 5 lines,
  90 reach 10, 27 reach 15 and 13 reach 20. 15 is where the count becomes a
  list someone can act on.
- **god-file: 64 findings before, 34 after.** The other 30 were files whose
  comments pushed them over a cap meant for code. Per repo, old → new: anchor
  8→2, codeintel 13→9, isayes 3→1, tally 12→7, provision 10→7, teleport 18→8.
- **`alias_drift` found the real thing it was written for.** On provision it
  reports exactly one record — `t` differs — which is the missing
  `--no-tests=warn`. Negative control: run against a copy of `aliases.toml`
  itself, it is silent.
- **`too_many_lines` measured before the threshold was set**, on a cold clippy
  per crate, because a warm one prints nothing. 150 fails 10 sites in 5 crates,
  175 fails 8 in 5, 200 fails 4 in 4, and 250 fails none — the longest function
  in the fleet is 242 lines. 200 was chosen: it is the setting that puts
  pressure on the four genuine outliers and on nothing else.
- **All six presets pass `provision validate`.**
- **Fast gate green end to end on provision, all 7 steps**, with the two new
  steps reporting: `cargo aliases` caught the stale `t`, `soft caps` reported
  code lines.
- **The full gate stops at step 7 on a consumer that has not taken the new lint
  block**, with `lint-drift: too_many_lines: expected "warn", found "allow"`.
  That is `lints-check` doing its job, and it is the negative control for this
  whole change: the canonical block moved, and the consumer was told.

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

- **`commented-out-code` has no escape hatch.** It is an error with no
  per-line suppression, which is survivable only because it is 0 hits fleet-
  wide and the patterns are narrow. The first legitimate hit — a doctest-like
  snippet in a `//` comment that happens to be a whole declaration — has to be
  rewritten as a doc comment or as prose. If that turns out to be common, the
  answer is a marker, not a looser pattern.
- **The comment rules cannot see raw strings.** `//` inside `r#".."#` is data,
  not a comment, and awk cannot know that without lexing Rust.
- **`alias_drift` checks `[alias]` and nothing else.** `[env]` carries
  `RUSTDOCFLAGS = "-D warnings"`, which is what makes `cargo docs` meaningful,
  and a consumer that drops it loses the check silently. It is not compared
  because a consumer has a legitimate reason to extend `[env]` and no
  legitimate reason to redefine one of our aliases.
- **`CAP_COMMENT_RATIO` is nearly inert at 40.** One file in the fleet reaches
  it. It is a ceiling against a future spiral rather than a description of
  today, and the honest reading of the measurement is that run length, not
  ratio, is where this fleet actually drifts.
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
