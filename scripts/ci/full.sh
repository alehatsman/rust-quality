#!/usr/bin/env bash
# ci/full.sh — shared pre-push gate. First failure stops the pipeline.
#
#   [1/9] cargo fmt --check
#   [2/9] build --locked --all-targets
#   [3/9] clippy -D warnings
#   [4/9] test  (nextest when present, plus doctests — nextest does not run them)
#   [5/9] rustdoc -D warnings   (catches broken intra-doc links)
#   [6/9] cargo deny check      (advisories + bans + licenses + sources)
#   [7/9] cargo machete         (unused dependencies)
#   [8/9] lints-check           (drift vs rust-quality/lints.toml)
#   [9/9] structural soft caps
#
# Project-agnostic core. Extra gates (coverage, semver, feature powerset, miri,
# MSRV) are separate presets — too slow or too project-specific for the push
# path. Wire them into a nightly or release task.
#
# Knobs: PKG_ARGS (--workspace), FEATURE_ARGS (--all-features), CAP_LOC (500).
#
# FEATURE_ARGS defaults to --all-features. Crates with mutually exclusive
# features must override it (FEATURE_ARGS="") or the gate cannot compile.
set -euo pipefail

PKG_ARGS="${PKG_ARGS:---workspace}"
FEATURE_ARGS="${FEATURE_ARGS:---all-features}"

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$(git rev-parse --show-toplevel)"

have() {  # have <binary> — on PATH or in the cargo bin dir
  command -v "$1" >/dev/null 2>&1 && return 0
  [ -x "${CARGO_HOME:-$HOME/.cargo}/bin/$1" ]
}

require() {  # require <binary> <install hint>
  if have "$1"; then
    return 0
  fi
  echo "  ✗ $1 not found — $2" >&2
  return 1
}

echo "[1/9] cargo fmt --check"
cargo fmt --all --check || { echo "  ✗ fix with: cargo fmt --all" >&2; exit 1; }

echo "[2/9] build (--locked, all targets)"
# shellcheck disable=SC2086
cargo build --locked --all-targets $PKG_ARGS $FEATURE_ARGS

echo "[3/9] clippy (-D warnings)"
# shellcheck disable=SC2086
cargo clippy --locked --all-targets $PKG_ARGS $FEATURE_ARGS -- -D warnings

echo "[4/9] test"
needs_doctests=0
if have cargo-nextest; then
  # shellcheck disable=SC2086
  cargo nextest run --locked $PKG_ARGS $FEATURE_ARGS
  needs_doctests=1   # nextest does not run doctests; cargo test does
else
  echo "  (cargo-nextest not installed — falling back to cargo test)"
  # shellcheck disable=SC2086
  cargo test --locked $PKG_ARGS $FEATURE_ARGS
fi
# nextest does not run doctests. `cargo test --doc` errors outright on a
# workspace with no lib target, so ask cargo metadata before reaching for it.
if [ "$needs_doctests" = "1" ]; then
  has_lib=$(cargo metadata --no-deps --format-version 1 2>/dev/null | python3 -c '
import json, sys
pkgs = json.load(sys.stdin)["packages"]
print("yes" if any(t["kind"] == ["lib"] for p in pkgs for t in p["targets"]) else "no")
' 2>/dev/null || echo "no")
  if [ "$has_lib" = "yes" ]; then
    echo "  doctests"
    # shellcheck disable=SC2086
    cargo test --locked --doc $PKG_ARGS $FEATURE_ARGS
  else
    echo "  (no lib target — no doctests)"
  fi
fi

echo "[5/9] rustdoc (-D warnings)"
# shellcheck disable=SC2086
RUSTDOCFLAGS="-D warnings" cargo doc --locked --no-deps $PKG_ARGS $FEATURE_ARGS >/dev/null

echo "[6/9] cargo deny check"
require cargo-deny "install with scripts/install-tools.sh" || exit 1
if [ ! -f deny.toml ]; then
  echo "  ✗ deny.toml missing — run the rq/sync-config preset" >&2
  exit 1
fi
cargo deny --all-features check

echo "[7/9] cargo machete (unused dependencies)"
require cargo-machete "install with scripts/install-tools.sh" || exit 1
cargo machete

echo "[8/9] lints-check (drift vs canonical lint block)"
bash "$SCRIPTS_DIR/lints-check.sh"

echo "[9/9] structural soft caps"
bash "$SCRIPTS_DIR/budget-status.sh" | sed 's/^/  /'

echo
echo "✓ All checks green — safe to push."
