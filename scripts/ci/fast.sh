#!/usr/bin/env bash
# ci/fast.sh — shared pre-commit gate. Cheap checks only, no full compile.
#
#   [1/5] Cargo.lock drift (--locked, metadata only)
#   [2/5] cargo fmt --check (whole tree — rustfmt does not compile, so it is
#         cheap enough that scoping to staged files buys nothing)
#   [3/5] cargo check --all-targets
#   [4/5] ai-lint on staged .rs files
#   [5/5] structural soft caps
#
# First failure stops the pipeline. Project-agnostic core; projects that need
# extra fast checks layer them in their own task after this gate.
#
# Knobs: PKG_ARGS (--workspace), FEATURE_ARGS (--all-features), CAP_LOC (500).
set -euo pipefail

PKG_ARGS="${PKG_ARGS:---workspace}"
FEATURE_ARGS="${FEATURE_ARGS:---all-features}"

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$(git rev-parse --show-toplevel)"

# ── [1/5] lockfile drift ──────────────────────────────────────────────────
# Pre-push re-checks this: a commit made with --no-verify or pushed from CI
# must not be trusted to have run the hook.
echo "[1/5] Cargo.lock (drift check)"
if ! cargo metadata --locked --format-version 1 >/dev/null 2>&1; then
  echo "  ✗ Cargo.lock is out of sync with Cargo.toml" >&2
  echo "    run 'cargo update --workspace', stage Cargo.lock, and re-commit" >&2
  exit 1
fi
echo "  ✓ Cargo.lock is in sync"

# ── [2/5] formatting ──────────────────────────────────────────────────────
echo "[2/5] cargo fmt --check"
if ! cargo fmt --all --check; then
  echo "  ✗ formatting differs — fix with: cargo fmt --all" >&2
  exit 1
fi
echo "  ✓ tree is rustfmt-clean"

# ── [3/5] type check ──────────────────────────────────────────────────────
echo "[3/5] cargo check --all-targets"
# shellcheck disable=SC2086  # PKG_ARGS/FEATURE_ARGS are intentionally word-split
cargo check --all-targets --locked $PKG_ARGS $FEATURE_ARGS

# ── [4/5] ai-lint on staged files ─────────────────────────────────────────
echo "[4/5] ai-lint (staged .rs files)"
bash "$SCRIPTS_DIR/ai-lint.sh"

# ── [5/5] soft caps ───────────────────────────────────────────────────────
echo "[5/5] structural soft caps"
bash "$SCRIPTS_DIR/budget-status.sh" | sed 's/^/  /'

echo
echo "✓ Fast checks green — full gate (scripts/ci/full.sh) runs on push."
