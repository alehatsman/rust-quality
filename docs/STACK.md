# The stack

What to reach for, and when not to. **Versions verified against crates.io on
2026-09-08.**

Defaults, not laws. Deviating is fine; deviating *silently* is not — write the
reason down in the manifest or the ADR. Companion: [RUST.md](RUST.md).

---

## Default stacks

**Focused CLI tool**

```toml
clap        = { version = "4", features = ["derive", "env"] }
anyhow      = "1"
thiserror   = "2"          # only if the tool also ships a lib
tracing     = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
serde       = { version = "1", features = ["derive"] }
```
Plus `assert_cmd` + `insta` in `[dev-dependencies]`. That is the whole list for
most tools. Add `indicatif` when there is a progress bar to draw, `owo-colors`
when there is colour, and nothing else without a reason.

**HTTP service**

```toml
tokio       = { version = "1", features = ["rt-multi-thread", "macros", "signal"] }
axum        = "0.8"
tower       = "0.5"
tower-http  = { version = "0.7", features = ["trace", "timeout", "compression-full"] }
serde       = { version = "1", features = ["derive"] }
serde_json  = "1"
sqlx        = { version = "0.9", features = ["runtime-tokio", "postgres", "macros"] }
thiserror   = "2"
anyhow      = "1"
tracing     = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter", "json"] }
```
`tokio` with `features = ["full"]` is a convenience that pulls in everything;
name the features you use.

---

## Runtime and async

| Need | Default | v | Notes |
|---|---|---|---|
| Async runtime | `tokio` | 1.53 | The ecosystem agrees on it. Interop with anything else costs adapters. |
| Minimal runtime | `smol` | — | Embedded, tiny binaries, or you want an explicit executor. |
| Future combinators | `futures` | 0.3 | Prefer `futures-util` alone if you only need `StreamExt`. |
| Stream adapters over tokio | `tokio-stream` | 0.1 | |
| Codec / framing / cancellation | `tokio-util` | 0.7 | `CancellationToken` lives here. |
| `dyn`-compatible async traits | `async-trait` | 0.1 | Only for `dyn`. Native AFIT for everything else. |
| Runtime introspection | `tokio-console` | 0.1 | Worth wiring once a service has real task counts. |

**`async-std` is dead** — discontinued March 2025, published as
RUSTSEC-2025-0052. Migrate to `smol` or `tokio`.

## HTTP

| Need | Default | v | Notes |
|---|---|---|---|
| Server | `axum` | 0.8 | Tokio-team backed, plain `tower::Service` middleware. 0.8 uses `{param}` path syntax and native async traits — drop `#[async_trait]` from extractors. |
| Middleware | `tower` + `tower-http` | 0.5 / 0.7 | Tracing, timeout, compression, CORS, limits. Do not hand-roll these. |
| Low level | `hyper` | 1.11 | Only when you are building the framework, not the app. |
| Client | `reqwest` | 0.13 | Use `rustls-tls`, not `native-tls`: no OpenSSL in your container. |
| gRPC | `tonic` + `prost` | 0.14 / 0.14 | |
| Rate limiting | `governor` | 0.10 | |
| In-process cache | `moka` | 0.12 | |

Alternatives that are fine but buy you nothing new: `actix-web` (mature, its own
actor-flavoured world), `poem`, `salvo`, `rocket`. Pick `axum` unless a
constraint forces otherwise.

## Serialization

| Need | Default | v | Notes |
|---|---|---|---|
| Everything | `serde` | 1.0 | Not optional. It is the interop contract. |
| JSON | `serde_json` | 1.0 | |
| TOML | `toml` | 1.1 | |
| Awkward shapes | `serde_with` | 3.23 | Before you hand-write a `Deserialize`. |
| JSON Schema | `schemars` | 1.2 | Derive the schema instead of maintaining one. |
| Compact binary | `postcard` / `rmp-serde` | — | `postcard` for embedded and internal wire formats. |
| Protobuf | `prost` | 0.14 | |

## Errors

| Context | Default | v |
|---|---|---|
| Library error types | `thiserror` | 2.0 |
| Application top level | `anyhow` | 1.0 |
| Human-facing reports | `color-eyre` | 0.6 |
| Compiler-grade diagnostics | `miette` | 7.6 |

`snafu` is good and adds context-selector ergonomics; it is not worth a second
error idiom in a fleet that already uses `thiserror`.

## CLI

| Need | Default | v | Notes |
|---|---|---|---|
| Argument parsing | `clap` (derive) | 4.6 | `features = ["derive", "env"]`. |
| Shell completions | `clap_complete` | 4.6 | Generate in `build.rs` or a hidden subcommand. |
| Man pages | `clap_mangen` | 0.3 | |
| Tiny binary, no derive | `lexopt` / `pico-args` | — | Only when binary size or compile time is the constraint. |
| Progress | `indicatif` | 0.18 | |
| Colour | `owo-colors` / `anstyle` | 4.4 / 1.0 | `anstyle` if you want colour types without a colouring library. |
| Tables | `comfy-table` | 8.0 | |
| Prompts | `inquire` | 0.9 | |
| Config files | `figment` or `config` | 0.10 / 0.15 | Layer defaults → file → env → flags. Below three sources, plain `serde` + `clap(env)` is enough. |
| Platform paths | `directories` | 6.0 | Do not hand-roll `~/.config`. |

## Observability

| Need | Default | v | Notes |
|---|---|---|---|
| Structured logging + spans | `tracing` | 0.1 | The default for services and libraries alike. `log` only for a tiny leaf lib. |
| Subscriber | `tracing-subscriber` | 0.3 | `env-filter` always, `json` in production. |
| OTel export | `opentelemetry` + `tracing-opentelemetry` | 0.32 / 0.33 | Bridge, do not replace `tracing`. |
| Metrics | `metrics` | 0.24 | Facade with swappable exporters. |

Log with message templates and fields, never `format!` into the message.
`M-LOG-STRUCTURED`.

## Data and storage

| Need | Default | v | Notes |
|---|---|---|---|
| SQL, async, raw SQL | `sqlx` | 0.9 | Compile-time-checked queries. Needs a live DB at build time unless you commit `.sqlx/` offline data — do that, and CI stops needing a database. |
| SQL, maximum type safety | `diesel` | 2.3 | Sync-first; `diesel-async` bolts on async. |
| ActiveRecord ergonomics | `sea-orm` | 2.0 | Built on sqlx. Reasonable if the team comes from Rails/Django. |
| Embedded SQLite | `rusqlite` | 0.40 | Sync and fine — wrap it in `spawn_blocking`. |
| Pooling | built into `sqlx` | — | `deadpool`/`bb8` only for non-sqlx resources. |

## Time, identity, text

| Need | Default | v | Notes |
|---|---|---|---|
| Dates and times | `jiff` | 0.2 | New code. IANA zones built in, DST-correct arithmetic, hard to misuse. Still 0.x — pin it. |
| Dates and times, ecosystem interop | `chrono` | 0.4 | When a dependency already speaks `chrono`. |
| Minimal / no-std time | `time` | 0.3 | |
| UUIDs | `uuid` | 1.26 | v7 for anything that gets stored and sorted. |
| Randomness | `rand` | 0.10 | 0.9 → 0.10 changed APIs; check the migration notes before upgrading. |
| Regex | `regex` | 1.13 | Linear time by construction. Do not reach for a backtracking engine. |
| URLs | `url` | 2.5 | |
| Iterator helpers | `itertools` | 0.15 | |
| UTF-8 paths | `camino` | 1.2 | `Utf8PathBuf` removes a whole class of `to_str().unwrap()`. |

## Collections and hashing

| Need | Default | v | Notes |
|---|---|---|---|
| Fast hasher, internal keys | `foldhash` | 0.2 | Not DoS-resistant. Never for keys from the network. |
| Fast hasher, alternative | `rustc-hash` | 2.1 | |
| Insertion-ordered map | `indexmap` | 2.14 | |
| Small vectors | `smallvec` | 1.16 | Only with a measured allocation problem. |
| Byte buffers | `bytes` | 1.12 | Cheap slicing for network code. |
| Concurrent map | `dashmap` | 6.2 | After you have rejected "one owner task". |
| Locks | `parking_lot` | 0.12 | std locks are good now. Use `parking_lot` for a measured reason, and then use it consistently. |
| Lazy statics | `std::sync::LazyLock` | — | `once_cell` only below its MSRV. |
| Atomic swap | `arc-swap` | 1.9 | Hot-reloadable config. |

## Parsing

| Need | Default | v | Notes |
|---|---|---|---|
| Parser combinators | `winnow` | 1.0 | The maintained line from `nom`. 1.0 is stable. |
| Lexer | `logos` | 0.16 | Derive a fast lexer, feed it to a parser. |
| Great error recovery | `chumsky` | 0.13 | Language tooling where diagnostics matter. |
| Grammar file | `pest` | — | When a readable grammar beats speed. |

`nom` 8 is alive and fine; new code goes to `winnow`.

## Parallelism and channels

| Need | Default | v |
|---|---|---|
| Data parallelism | `rayon` | 1.12 |
| Async channels | `tokio::sync::{mpsc, broadcast, watch}` | — |
| Sync channels | `crossbeam-channel` | 0.5 |
| Both worlds | `flume` | 0.12 |

## Crypto and TLS

| Need | Default | v | Notes |
|---|---|---|---|
| TLS | `rustls` | 0.23 | Default everywhere. Removes OpenSSL from your build and your container. |
| Hashing | `sha2` / `blake3` | 0.11 / 1.8 | `blake3` when speed matters and interop does not. |
| Password hashing | `argon2` | 0.6 | Never a plain hash. |
| Secrets in memory | `secrecy` + `zeroize` | 0.10 / 1.9 | Keeps secrets out of `Debug` output. |
| Encoding | `base64` / `hex` | 0.23 / 0.4 | |

Do not write your own crypto, and do not pin an unaudited fork of someone
else's.

## Testing

| Need | Default | v | Notes |
|---|---|---|---|
| Test runner | `cargo-nextest` | — | Process isolation, retries, JUnit. Does not run doctests. |
| Fixtures and cases | `rstest` | 0.27 | |
| Property tests | `proptest` | 1.11 | |
| Snapshots | `insta` | 1.48 | `cargo insta review` is the whole workflow. |
| CLI assertions | `assert_cmd` + `predicates` | 2.2 / 3.1 | `trycmd` for a directory of transcript tests. |
| HTTP mocking | `wiremock` | 0.6 | |
| Real dependencies | `testcontainers` | 0.28 | Integration tests against the actual database. |
| Trait mocks | `mockall` | 0.15 | Last resort — write a fake first. |
| Temp files | `tempfile` | 3.27 | |

## Benchmark and profile

| Need | Default | v | Notes |
|---|---|---|---|
| Microbenchmarks | `divan` | 0.1 | Less ceremony than criterion. |
| Statistical benchmarks | `criterion` | 0.8 | When you need confidence intervals and regression tracking. |
| CLI wall-clock | `hyperfine` | — | Binary, not a crate. |
| Sampling profiler | `samply` | — | Cross-platform, opens in the Firefox profiler. |
| Flamegraphs | `cargo-flamegraph` | — | Linux `perf` / macOS DTrace. |

## Build, release, ship

| Need | Default | Notes |
|---|---|---|
| Release automation | `release-plz` | Release PR from conventional commits, changelog, semver check, publish. |
| Binary artifacts | `dist` (formerly `cargo-dist`) | Cross-platform archives, installers, GitHub release. |
| Installing tools | `cargo-binstall` | Prebuilt binaries instead of a source build. |
| Docker | `cargo-chef` + distroless/scratch | Cache the dependency layer; ship a stripped static binary. |
| Allocator for apps | `mimalloc` | Measurable win in allocation-heavy services. `M-MIMALLOC-APPS`. |
| Linker | LLD (default on x86_64-linux since 1.90) | `mold` or `wild` if link time still hurts. |

## Deliberately not picked

| Crate | Why not |
|---|---|
| `async-std` | Discontinued, RUSTSEC-2025-0052. |
| `lazy_static` | `std::sync::LazyLock` does it. |
| `failure`, `error-chain` | Superseded by `thiserror`/`anyhow`. |
| `structopt` | Merged into `clap` 4 derive. |
| `native-tls` / `openssl` | `rustls` avoids a system dependency and a class of build failures. |
| `ahash` | `foldhash` is the current answer. Not wrong, just no longer the default. |
| `cargo-udeps` | Nightly-only; `cargo-machete` is stable. |
| `chrono` in new code | `jiff` is harder to misuse. Interop is the only reason to prefer it. |

## Watch list

Not defaults yet. Re-check next quarter.

- **`facet`** — reflection-based serialization aiming at `serde`'s job with far
  less generated code. Interesting, not load-bearing.
- **Cranelift / TPDE backends** — debug-build compile times, still not the
  stable default.
- **`dynosaur` / `trait-variant`** — the eventual answer to `dyn` async traits.
  `async-trait` still wins on stability today.
- **`hotpath`** — answers "why is this slow" where criterion only answers "is
  this faster".
