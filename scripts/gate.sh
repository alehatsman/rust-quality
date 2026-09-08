#!/usr/bin/env bash
# gate.sh — the quality gate. `gate.sh fast` before a commit, `gate.sh full`
# before a push. First failure stops the run.
#
# There is no per-command wrapper here and no preset for `cargo build`. Cargo
# already is the interface; wrapping `cargo check` in YAML adds a file and
# removes nothing. What this script owns is the part cargo cannot express:
# ordering, fail-fast, and four gotchas that silently pass otherwise —
#
#   * nextest never runs doctests, so they need a second invocation
#   * `cargo test --doc` hard-errors on a workspace with no lib target
#   * clippy compiles everything, so a separate `cargo build` step is a wasted
#     full compile — dropped
#   * `[workspace.lints]` does nothing until members opt in — lints-check
#
# Knobs: PKG_ARGS (--workspace), FEATURE_ARGS (--all-features), CAP_LOC (500).
# FEATURE_ARGS must be "" for crates with mutually exclusive features.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
. "$HERE/lib.sh"

PKG_ARGS="${PKG_ARGS:---workspace}"
FEATURE_ARGS="${FEATURE_ARGS:---all-features}"
MODE="${1:-full}"

cd "$(git rev-parse --show-toplevel)"

have() { command -v "$1" >/dev/null 2>&1 || [ -x "${CARGO_HOME:-$HOME/.cargo}/bin/$1" ]; }
step() { printf '[%s/%s] %s\n' "$1" "$TOTAL" "$2"; }

# render <title> — turn lib.sh records on stdin into an indented human report.
render() {
  local n=0 rule level path lineno msg
  while IFS=$'\t' read -r rule level path lineno msg; do
    printf '  %s:%s: %s: %s\n' "$path" "$lineno" "$rule" "$msg"
    n=$((n + 1))
    [ "$level" = "error" ] && FAILED=1
  done
  if [ "$n" -eq 0 ]; then printf '  ✓ %s: clean\n' "$1"; fi
}
FAILED=0

case "$MODE" in
# ── fast: pre-commit. No full build, no network, no extra tools. ─────────────
fast)
  TOTAL=5
  step 1 "Cargo.lock (drift)"
  if ! cargo metadata --locked --format-version 1 >/dev/null 2>&1; then
    if [ -f Cargo.lock ]; then
      echo "  ✗ Cargo.lock is stale — run 'cargo update --workspace', stage it, re-commit" >&2
    else
      echo "  ✗ Cargo.lock is missing — run 'cargo generate-lockfile', stage it, re-commit" >&2
    fi
    exit 1
  fi
  echo "  ✓ in sync"

  step 2 "cargo fmt --check"
  cargo fmt --all --check || { echo "  ✗ fix with: cargo fmt --all" >&2; exit 1; }
  echo "  ✓ rustfmt-clean"

  # clippy, not `cargo check`: it type-checks anyway, so it is the same work
  # for strictly more signal. That is one fewer step than the obvious design.
  step 3 "clippy"
  # shellcheck disable=SC2086
  cargo clippy --locked --all-targets $PKG_ARGS $FEATURE_ARGS -- -D warnings

  step 4 "ai-lint (staged)"
  mapfile -t files < <(staged_rs)
  if [ "${#files[@]}" -eq 0 ]; then echo "  (no staged .rs files)"; else
    render "ai-lint" < <(ai_lint "${files[@]}")
  fi

  step 5 "soft caps"
  render "soft caps" < <(god_files; dup_deps)
  ;;

# ── full: pre-push. ──────────────────────────────────────────────────────────
full)
  TOTAL=8
  step 1 "cargo fmt --check"
  cargo fmt --all --check || { echo "  ✗ fix with: cargo fmt --all" >&2; exit 1; }

  step 2 "clippy (-D warnings)"
  # shellcheck disable=SC2086
  cargo clippy --locked --all-targets $PKG_ARGS $FEATURE_ARGS -- -D warnings

  step 3 "test"
  if have cargo-nextest; then
    # shellcheck disable=SC2086
    cargo nextest run --locked $PKG_ARGS $FEATURE_ARGS
    if cargo metadata --no-deps --format-version 1 2>/dev/null \
        | grep -q '"kind":\["lib"\]'; then
      echo "  doctests (nextest does not run them)"
      # shellcheck disable=SC2086
      cargo test --locked --doc $PKG_ARGS $FEATURE_ARGS
    else
      echo "  (no lib target — no doctests)"
    fi
  else
    echo "  (cargo-nextest absent — cargo test, which does run doctests)"
    # shellcheck disable=SC2086
    cargo test --locked $PKG_ARGS $FEATURE_ARGS
  fi

  step 4 "rustdoc (-D warnings)"
  # shellcheck disable=SC2086
  RUSTDOCFLAGS="-D warnings" cargo doc --locked --no-deps $PKG_ARGS $FEATURE_ARGS >/dev/null

  step 5 "cargo deny"
  have cargo-deny || { echo "  ✗ cargo-deny missing — scripts/tools.sh install" >&2; exit 1; }
  [ -f deny.toml ] || { echo "  ✗ deny.toml missing — run the rq/sync-config preset" >&2; exit 1; }
  cargo deny --all-features check

  step 6 "cargo machete"
  have cargo-machete || { echo "  ✗ cargo-machete missing — scripts/tools.sh install" >&2; exit 1; }
  cargo machete

  step 7 "lint block drift"
  bash "$HERE/lints-check.sh"

  step 8 "soft caps"
  render "soft caps" < <(god_files; dup_deps)
  ;;

*)
  echo "usage: gate.sh [fast|full]" >&2; exit 2 ;;
esac

[ "$FAILED" -eq 0 ] || { echo; echo "✗ gate failed on the findings above." >&2; exit 1; }
echo
if [ "$MODE" = "fast" ]; then
  echo "✓ fast checks green — full gate runs on push."
else
  echo "✓ all checks green — safe to push."
fi
