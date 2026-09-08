#!/usr/bin/env bash
# budget-status — print current state of the structural soft caps.
#
# Soft caps (generic, project-agnostic):
#   1. God files > 500 LOC (non-test)         → refactor on next touch
#   2. Duplicate dependency versions           → informational
#
# Neither fails the gate. Both are printed on every commit and push so drift is
# visible rather than discovered during a rewrite.
#
# Cyclomatic/cognitive complexity is deliberately NOT here: clippy owns it via
# `cognitive_complexity` + `cognitive-complexity-threshold` in clippy.toml, so
# it is enforced by the lint gate with no second compile and no extra tool.
#
# Duplicate versions are Rust-specific and have no Go analogue: two copies of
# the same crate are two copies in the binary, two sets of `build.rs` running,
# and — when the crate has a type in a public API — a genuine type mismatch.
#
# Usage:
#   bash scripts/budget-status.sh                # human report
#   bash scripts/budget-status.sh --format jsonl # structured findings
set -euo pipefail

CAP_LOC="${CAP_LOC:-500}"

FORMAT="text"
while [ $# -gt 0 ]; do
  case "$1" in
    --format)   FORMAT="${2:-}"; shift 2 ;;
    --format=*) FORMAT="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

cd "$(git rev-parse --show-toplevel)"

# god_files — non-test .rs files over CAP_LOC, as "<loc> <path>" lines.
god_files() {
  git ls-files -- '*.rs' \
    | grep -vE '(^|/)(target|vendor)/|(^|/)(tests|benches|examples)/|\.pb\.rs$|_generated\.rs$' \
    | tr '\n' '\0' \
    | xargs -0 wc -l 2>/dev/null \
    | awk -v cap="$CAP_LOC" '$1 > cap && $2 != "total" {print $1, $2}'
}

# dup_deps — crate names resolved to more than one version. Offline: the
# lockfile is the source of truth and the gate must not hit the network.
dup_deps() {
  command -v cargo >/dev/null 2>&1 || return 0
  [ -f Cargo.lock ] || return 0
  cargo tree --workspace --duplicates --edges normal --offline 2>/dev/null \
    | grep -E '^[a-zA-Z0-9_.-]+ v[0-9]' \
    | awk '{print $1}' | sort -u || true
}

# --- jsonl findings feed ------------------------------------------------------
# Both caps are informational (this script never fails), so both emit at
# level:warning. Self-contained branch so the human report stays untouched.
if [ "$FORMAT" = "jsonl" ]; then
  god_files | while read -r loc path; do
    printf '{"tool":"budget","rule":"god-file","level":"warning","path":"%s","line":1,"message":"%s LOC (cap %s)","fingerprint":"god-file:%s:1"}\n' \
      "$path" "$loc" "$CAP_LOC" "$path"
  done
  dup_deps | while read -r name; do
    printf '{"tool":"budget","rule":"duplicate-dep","level":"warning","path":"Cargo.lock","line":1,"message":"%s resolves to more than one version","fingerprint":"duplicate-dep:Cargo.lock:%s"}\n' \
      "$name" "$name"
  done
  exit 0
fi

if [ -t 1 ]; then
  bold=$(tput bold 2>/dev/null || true)
  red=$(tput setaf 1 2>/dev/null || true)
  yellow=$(tput setaf 3 2>/dev/null || true)
  green=$(tput setaf 2 2>/dev/null || true)
  reset=$(tput sgr0 2>/dev/null || true)
else
  bold='' red='' yellow='' green='' reset=''
fi

printf '%sStructural soft caps — current state%s\n' "$bold" "$reset"
echo

# --- 1. god files -------------------------------------------------------------
gf="$(god_files || true)"
if [ -n "$gf" ]; then
  n=$(printf '%s\n' "$gf" | wc -l | tr -d ' ')
  printf '%s✗%s god files (> %s LOC, non-test): %s\n' "$red" "$reset" "$CAP_LOC" "$n"
  printf '%s\n' "$gf" | sort -rn | head -5 | awk '{printf "    %6d  %s\n", $1, $2}'
else
  printf '%s✓%s god files (> %s LOC, non-test): none\n' "$green" "$reset" "$CAP_LOC"
fi

# --- 2. duplicate dependency versions -----------------------------------------
dd="$(dup_deps || true)"
if [ -n "$dd" ]; then
  n=$(printf '%s\n' "$dd" | wc -l | tr -d ' ')
  printf '%s⚠%s duplicate dependency versions: %s\n' "$yellow" "$reset" "$n"
  printf '%s\n' "$dd" | head -5 | sed 's/^/    /'
  printf '    inspect with: cargo tree --duplicates\n'
else
  printf '%s✓%s duplicate dependency versions: none\n' "$green" "$reset"
fi
