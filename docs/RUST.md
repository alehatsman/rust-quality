# Rust, done properly

Baseline: **Rust 1.98, edition 2024, 2026-09.** Rules, not essays. `[gate]` marks
what `rq/ci` enforces — everything else is review surface.

Companion: [STACK.md](STACK.md) — what to reach for.

---

## 0. Before the first line

1. **Spec first for anything non-trivial.** Goal, scope, interfaces, edge cases,
   validation. Rust punishes retrofitted design harder than most languages: the
   type you pick in hour one shows up in every signature by hour ten.
2. **Boring tech, few deps, small interfaces.** Every dependency is code you
   ship and a `build.rs` you execute.
3. **Smallest crate that does the job.** Splitting later costs a refactor;
   splitting up front costs a directory. `M-SMALLER-CRATES`.

## 1. Toolchain and edition

4. **Pin the toolchain.** `rust-toolchain.toml` with an exact version, not
   `stable`. "Works on my machine" is a version skew.
   ```toml
   [toolchain]
   channel = "1.98.1"
   components = ["clippy", "rustfmt"]
   ```
5. **Edition 2024 for anything new.** `M-LATEST-EDITION`.
6. **Set `rust-version`.** It is your MSRV, and since 1.84 the resolver uses it
   to pick dependency versions that still build. Binaries: whatever you ship
   with. Libraries: conservative, bumped in a minor release, policy in the
   README.
7. **Lint levels live in the manifest, not in attributes.** One
   `[workspace.lints]` block, every member `[lints] workspace = true`. Scattered
   `#![allow]` at the top of files is how a codebase stops being linted. [gate]
8. **Suppress with `#[expect(..., reason = "...")]`, never `#[allow]`.**
   `expect` warns once the problem is gone; `allow` rots silently. [gate]

## 2. Project shape

9. **Workspace at the root, crates as flat siblings** under `crates/`. Nested
   crate trees make paths and `cargo -p` miserable. `M-CRATES-FLAT-FOLDER`.
10. **Versions once, in `[workspace.dependencies]`.** Members write
    `serde.workspace = true`. Two versions of one crate in a workspace is a bug
    you will find at link time. [gate: duplicate-dep]
11. **Library plus a thin binary.** `main.rs` parses arguments, builds config,
    calls into the lib, maps errors to an exit code. Nothing else. Logic in a
    `main.rs` is logic you cannot unit-test.
12. **No `mod.rs`.** `foo.rs` beside `foo/`.
13. **Features are additive, always.** A feature may add API; it may never
    remove or change one. Verify with the feature powerset (`rq/features`), not
    by hoping. `M-FEATURES-ADDITIVE`.
14. **One public path per item.** Re-exporting the same type through three
    modules triples the API surface an agent has to reason about.
    `M-SINGLE-ITEM-PATH`. No glob re-exports, no preludes.
15. **`pub(crate)` is the default reach.** `pub` is a promise. [gate:
    `unreachable_pub`]

## 3. Types and API surface

16. **Newtype over primitives.** `struct Port(u16)` cannot be passed where a
    `UserId` belongs. Validate in the constructor, keep the field private, and
    the invariant holds everywhere by construction. `M-STRONG-TYPES-GUARD`.
17. **Parse, don't validate.** Turn unstructured input into a type that cannot
    be wrong, once, at the boundary. Everything downstream stops re-checking.
18. **Concrete types > generics > `dyn`.** Reach for the next one only when the
    previous cannot express it. `M-DI-HIERARCHY`.
19. **Accept borrowed and general, return owned and concrete.**
    `impl AsRef<Path>`, `&str`, `impl IntoIterator` in; `String`, `PathBuf`,
    a named struct out. Never return `impl Trait` from a public API you might
    need to name.
20. **`#[non_exhaustive]` on public enums and structs you expect to extend.**
    Adding a variant is otherwise a breaking change forever.
21. **Builders once a constructor takes more than three arguments or any
    optional one.** `bon` generates a typestate builder that will not compile
    with a required field missing. Validate in `.build()`, not in the setters.
22. **`#[must_use]` on anything pure.** A discarded return is a bug.
23. **`Debug` on every public type; `Display` on errors and anything a user
    reads.** Redact secrets in a hand-written `Debug` and unit-test the
    redaction. `M-PUBLIC-DEBUG`.
24. **Name things short and specific.** No `Manager`, `Service`, `Helper`,
    `Util`. Two words maximum, no module prefix on the item.

## 4. Errors

25. **Libraries: one `thiserror` enum per boundary.** Structured variants,
    `#[from]` for conversions, `#[non_exhaustive]`, no `Box<dyn Error>` in
    public signatures. Callers must be able to match.
26. **Applications: `anyhow`** (or `color-eyre` when the report is read by a
    human), with `.context()` added at every layer you cross.
27. **`?` and `From`, never `map_err(|_| ...)`.** Dropping the cause turns a
    five-second diagnosis into an afternoon. [gate: `map_err_ignore`]
28. **Carry data, not a formatted string.** `Error::Timeout { after: Duration }`
    beats `Error::Other(String)`; the caller can react to the first one.
29. **Errors are for the caller, logs are for you.** Do not log-and-return the
    same failure at every level — pick the boundary that owns the decision.

## 5. Panics

30. **A panic means "a programmer made a mistake, stop".** It is never a control
    flow mechanism and never a response to bad input. `M-PANIC-IS-STOP`.
31. **Detected bugs panic; expected failures return `Result`.** Inverting this
    gives you either crashes on user input or `Result` on impossible states.
    `M-PANIC-ON-BUG`.
32. **`expect("invariant that makes this safe")`, not `unwrap()`.** The message
    is the proof. [gate: `unwrap_used`]
33. **No indexing and no string slicing in production code.** `v[i]` panics,
    `&s[..n]` panics on a UTF-8 boundary. `.get()` and `char_indices()` do not.
    [gate: `indexing_slicing`, `string_slice`]
34. **Tests are exempt** — that is what `clippy.toml`'s `allow-*-in-tests` is
    for. Panicking is a test's job.

## 6. Async

35. **Tokio unless you have a specific reason.** One runtime per process,
    `#[tokio::main]` only in `main`. Libraries take a handle or stay runtime
    agnostic; they do not start a runtime.
36. **Native `async fn` in traits.** Stable since 1.75. Reach for `async-trait`
    only when you genuinely need `dyn Trait` — AFIT is still not dyn-compatible
    as of 1.98.
37. **Never hold a `std::sync::Mutex` guard across `.await`.** It is a deadlock
    with extra steps. Restructure so the lock closes before the await; use
    `tokio::sync::Mutex` only when you truly must hold across one. [gate:
    `await_holding_lock`]
38. **CPU-bound work leaves the reactor.** `spawn_blocking` for blocking I/O,
    `rayon` for parallel compute. A single blocking call stalls every task on
    that worker.
39. **Every spawned task has an owner.** Keep the `JoinHandle`, or use a
    `JoinSet`/`TaskTracker`. A detached task that panics disappears silently.
40. **Cancellation is a drop.** Anything after an `.await` may never run, so no
    cleanup lives only on the happy path. Use RAII guards or
    `CancellationToken`.
41. **Timeouts on every external call.** No timeout is a hang waiting for
    production.
42. **Yield in long loops.** A task that never awaits starves its worker.
    `M-YIELD-POINTS`.

## 7. Concurrency

43. **Data parallelism → `rayon`. Message passing → channels. Shared mutable
    state → last resort.** In that order.
44. **`Arc<Mutex<HashMap<..>>>` is a design smell.** Either one owner task with
    a channel, or a concurrent map. Pick deliberately.
45. **`Arc::clone(&x)`, not `x.clone()`.** The reader should see the refcount
    bump. [gate: `clone_on_ref_ptr`]
46. **`Rc<Mutex<_>>` is always wrong** — single-threaded needs no mutex,
    multi-threaded needs `Arc`. [gate: `rc_mutex`]

## 8. Unsafe

47. **`unsafe_code = "warn"` everywhere.** A crate that needs it opts out
    explicitly, in its own manifest, with a reason. [gate]
48. **Minimal blocks, one operation each, `// SAFETY:` naming the invariant.**
    "Trust me" is not a safety comment. [gate: `undocumented_unsafe_blocks`,
    `multiple_unsafe_ops_per_block`]
49. **Wrap it in a safe API whose signature makes the invariant unviolable.**
    If a caller can trigger UB without writing `unsafe`, the wrapper is unsound
    and unsound is a bug even when nothing crashes. `M-UNSOUND`.
50. **Run Miri** (`rq/miri`) and fuzz anything that parses bytes. The borrow
    checker is static; UB is dynamic.
51. **Valid reasons for unsafe: FFI, a genuinely novel abstraction, or a
    profiled hot path.** "It was easier" is not one.

## 9. Testing

52. **Unit tests in `#[cfg(test)] mod tests` beside the code; integration tests
    in `tests/`; doctests as documentation.** Three layers, three jobs.
53. **`cargo nextest run` for the suite, `cargo test --doc` for doctests.**
    nextest does not run doctests. Losing them is silent. [gate]
54. **Test observable behavior, not branches.** A test that mirrors the
    implementation passes forever and catches nothing.
    `M-TAUTOLOGICAL-TESTS`.
55. **Fakes over mock frameworks.** An in-memory implementation of your own
    trait is faster to write, faster to run, and does not encode call order as
    a requirement. Reach for `mockall` only when the trait is wide and the
    interactions are the thing under test.
56. **Inject time and randomness.** Code that calls `now()` or `rand()` inside
    the logic cannot be tested; take a `Clock` and a seeded RNG.
57. **Property tests for invariants, snapshots for structured output.**
    `proptest` finds the input you did not think of; `insta` makes a diff
    reviewable instead of a wall of assertions.
58. **Make I/O and syscalls mockable at a trait boundary.**
    `M-MOCKABLE-SYSCALLS`.

## 10. Documentation

59. **First sentence: one line, ~15 words, what it does.** It is what shows in
    the item list and what an agent reads first.
60. **Module docs on every module, crate docs on `lib.rs`.** Explain the shape,
    not the history — no design narratives, no changelogs in doc comments.
    `M-NO-META-DESIGN-DOCUMENTATION`.
61. **Examples that compile.** Doctests are the only documentation that cannot
    rot.
62. **`rustdoc -D warnings` in the gate.** A broken intra-doc link is a
    documentation bug with a compiler that can find it. [gate]

## 11. Performance

63. **Measure first, always.** `samply` or `cargo flamegraph` for *where*,
    `divan`/`criterion` for *how much*, `hyperfine` for CLI wall-clock. A guess
    about a Rust hot path is wrong about as often as a coin flip.
64. **Set the profiles once.**
    ```toml
    [profile.release]
    lto = "thin"
    codegen-units = 1
    strip = true
    # panic = "abort"   # binaries only, and only if you have no unwind story

    [profile.dev.package."*"]
    opt-level = 2       # optimized deps, fast-compiling own code
    ```
65. **Allocate less before you allocate faster.** `with_capacity`,
    `shrink_to_fit` after building, reuse buffers in loops, `Box<str>` /
    `Box<[T]>` for immutable owned sequences. `M-MEM-REUSE`, `M-BOX-DST`.
66. **Fast hasher for internal maps** (`foldhash`, `rustc-hash`) — never for a
    map whose keys come from an untrusted source. `M-FAST-HASHER`.
67. **`&str` and `&[T]` in hot signatures**, not `String` and `Vec`.
68. **Never `.clone()` to silence the borrow checker.** That is the compiler
    telling you the ownership model is wrong; restructure instead.

## 12. Supply chain

69. **`cargo deny check` in the gate** — advisories, licenses, bans, sources.
    One tool, one config, no excuses. [gate]
70. **Read the `build.rs` of every dependency you add.** In August 2026
    `arrayref`, `internment` and `append-only-vec` were published with a
    poisoned `proc-macro1` dependency that executed at *compile time*. Building
    was enough.
71. **Unmaintained is a vulnerability class.** `async-std`'s discontinuation
    shipped as RUSTSEC-2025-0052. Your advisory gate should already be shouting
    about it.
72. **Commit `Cargo.lock` for binaries. `cargo install --locked`, always.**
    Without it, install-time resolution picks whatever was published five
    minutes ago.
73. **Fewer dependencies is a security control**, not an aesthetic preference.

## 13. Traps — 2026 edition

Each of these has cost somebody a day.

| Trap | Reality |
|---|---|
| `imports_granularity` / `group_imports` in `rustfmt.toml` | Nightly-only. On stable rustfmt they are silently ignored — you are not formatting imports. |
| Lint group without `priority = -1` | The group re-enables everything your `allow` entries just turned off. |
| `[workspace.lints]` alone | Does nothing until every member declares `[lints] workspace = true`. |
| `cargo clippy` on a warm cache | Emits nothing. A "clean" CI step can mean "did not run". |
| `cargo nextest run` | Runs no doctests. Ever. |
| `cargo test --doc` on a bin-only workspace | Hard error, not a skip. |
| `--all-features` | Cannot build crates with mutually exclusive features. |
| `async fn` in a trait behind `dyn` | Not dyn-compatible in 1.98. `async-trait` or an enum. |
| `cargo machete` | False-positives on deps used only in `build.rs` or through a macro. Add an `ignored` entry, do not delete the dep. |
| `sqlx` compile-time checks | Need a live database unless `.sqlx/` offline data is committed. |
| `std::env::set_var` | `unsafe` in edition 2024. It always was; now it says so. |
| `panic = "abort"` | Breaks `#[should_panic]` tests and any unwind-based recovery. |

## 14. Review checklist

- [ ] Does a wrong value have a type that makes it unrepresentable?
- [ ] Can the caller match on the error, or did we hand them a string?
- [ ] Any `unwrap`, index, or slice on a path that touches user input?
- [ ] Does every `.await` survive being cancelled at that exact point?
- [ ] Is any lock held across an `.await`?
- [ ] Does every spawned task have an owner?
- [ ] Is there a timeout on every external call?
- [ ] Is each new dependency justified, and did someone read its `build.rs`?
- [ ] Do the tests assert behavior, or do they mirror the implementation?
- [ ] Does every `#[expect]` carry a reason someone can check later?
- [ ] Is the public surface as small as it can be?
- [ ] Would the first doc sentence tell a stranger what this is?

## Upstream

- [Rust API Guidelines](https://rust-lang.github.io/api-guidelines/) — the `C-*` checklist.
- [Pragmatic Rust Guidelines](https://microsoft.github.io/rust-guidelines/) — the `M-*` rules cited above. Read the AI and Correctness sections in full.
- [The Rust Performance Book](https://nnethercote.github.io/perf-book/)
- [Effective Rust](https://effective-rust.com/)
- [RustSec Advisory Database](https://rustsec.org/)
