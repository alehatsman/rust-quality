#!/usr/bin/env bash
# tools.sh install | check — the three tools the gate actually runs, plus the
# two rustup components.
#
# Trimmed from six on purpose. cargo-llvm-cov, cargo-semver-checks and
# cargo-hack were installed by the old layout for presets that most repos never
# run; a setup step that installs tools you do not use is friction charged to
# every contributor. They are named at the bottom for when you need them.
#
# `--locked` is not optional: without it cargo resolves fresh dependency
# versions at install time, which is precisely the window the August 2026
# crates.io build-script attacks used.
set -euo pipefail

crates=(
  cargo-nextest   # per-test process isolation, retries, JUnit
  cargo-deny      # advisories + licenses + bans + sources, one config
  cargo-machete   # unused dependencies, stable channel
)

cargo_bin="${CARGO_HOME:-$HOME/.cargo}/bin"
have() { command -v "$1" >/dev/null 2>&1 || [ -x "$cargo_bin/$1" ]; }

case "${1:-check}" in
install)
  if command -v rustup >/dev/null 2>&1; then
    echo "→ rustup component add clippy rustfmt"
    rustup component add clippy rustfmt
  fi
  if have cargo-binstall; then
    echo "→ cargo binstall ${crates[*]}"
    cargo binstall --no-confirm --locked "${crates[@]}"
  else
    echo "  (no cargo-binstall — building from source; 'cargo install cargo-binstall' makes this fast)"
    for c in "${crates[@]}"; do
      echo "→ cargo install --locked $c"
      cargo install --locked "$c"
    done
  fi
  echo
  echo "✓ installed. Optional, on demand:"
  echo "    cargo-llvm-cov       coverage        cargo llvm-cov nextest --lcov --output-path lcov.info"
  echo "    cargo-semver-checks  API breakage    cargo semver-checks check-release"
  echo "    cargo-hack           feature powerset cargo hack check --feature-powerset --depth 2"
  echo "    miri                 UB detection    rustup +nightly component add miri && cargo +nightly miri test"
  ;;
check)
  missing=0
  for t in cargo rustc cargo-clippy rustfmt "${crates[@]}"; do
    if have "$t"; then printf '  ✓ %s\n' "$t"
    else printf '  ✗ %s — MISSING\n' "$t"; missing=$((missing + 1)); fi
  done
  [ "$missing" -eq 0 ] || { echo; echo "$missing missing. Run: scripts/tools.sh install"; exit 1; }
  ;;
*)
  echo "usage: tools.sh [install|check]" >&2; exit 2 ;;
esac
