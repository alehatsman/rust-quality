#!/usr/bin/env bash
# install-tools — install every tool the gate depends on. Idempotent.
#
# Uses `cargo binstall` when present (pulls prebuilt binaries; seconds instead
# of minutes) and falls back to `cargo install --locked`. `--locked` is not
# optional: without it cargo resolves fresh dependency versions at install
# time, which is exactly the window the August 2026 crates.io build-script
# attacks used.
#
# Verify after with: scripts/check-tools.sh
set -euo pipefail

# rustup components first — clippy and rustfmt ship with the toolchain but are
# not always selected in minimal profiles (CI images, containers).
if command -v rustup >/dev/null 2>&1; then
  echo "→ rustup component add clippy rustfmt"
  rustup component add clippy rustfmt
fi

crates=(
  cargo-nextest        # test runner: per-test process isolation, retries, JUnit
  cargo-deny           # advisories + licenses + bans + sources, one config
  cargo-machete        # unused dependencies, stable channel (udeps needs nightly)
  cargo-llvm-cov       # coverage via LLVM instrumentation
  cargo-semver-checks  # public API breakage vs the published version
  cargo-hack           # feature powerset / --each-feature builds
)

if command -v cargo-binstall >/dev/null 2>&1; then
  echo "→ cargo binstall ${crates[*]}"
  cargo binstall --no-confirm --locked "${crates[@]}"
else
  echo "  (cargo-binstall not found — building from source; consider"
  echo "   'cargo install cargo-binstall' to make this fast)"
  for c in "${crates[@]}"; do
    echo "→ cargo install --locked $c"
    cargo install --locked "$c"
  done
fi

echo
echo "✓ Tools installed. Verify with scripts/check-tools.sh."
echo "  Optional, not installed here:"
echo "    miri            rustup +nightly component add miri   (crates with unsafe)"
echo "    cargo-mutants   mutation testing, out-of-band"
echo "    cargo-public-api / release-plz  release engineering"
