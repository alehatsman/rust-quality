#!/usr/bin/env bash
# clippy-findings — project clippy's native JSON diagnostics into the shared
# finding schema, so the lint gate's real output reaches agents unfiltered.
#
# This is the emitter that carries the most signal: everything in lints.toml
# lands here with a file, a line, a rule name and a stable fingerprint.
#
# Clippy caches aggressively — a warm run emits nothing at all. `cargo clean -p`
# on each workspace package (deps stay cached) forces a real pass. Skip it with
# --no-clean when the caller already knows the cache is cold.
#
# Diagnostics from outside the workspace (registry deps, generated code in
# OUT_DIR) are dropped: they are not actionable in this repo.
#
# Usage:
#   bash scripts/clippy-findings.sh                # human passthrough
#   bash scripts/clippy-findings.sh --format jsonl # structured findings
#   bash scripts/clippy-findings.sh --no-clean
set -euo pipefail

FORMAT="text"
CLEAN=1
while [ $# -gt 0 ]; do
  case "$1" in
    --format)   FORMAT="${2:-}"; shift 2 ;;
    --format=*) FORMAT="${1#*=}"; shift ;;
    --no-clean) CLEAN=0; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

case "$FORMAT" in
  text|jsonl) ;;
  *) echo "clippy-findings: unknown --format '$FORMAT' (want text|jsonl)" >&2; exit 2 ;;
esac

PKG_ARGS="${PKG_ARGS:---workspace}"
FEATURE_ARGS="${FEATURE_ARGS:---all-features}"

say() { if [ "$FORMAT" = "jsonl" ]; then echo "$@" >&2; else echo "$@"; fi; }

cd "$(git rev-parse --show-toplevel)"

if ! command -v cargo >/dev/null 2>&1 || [ ! -f Cargo.toml ]; then
  say "  clippy-findings: no cargo / no Cargo.toml — skipped."
  exit 0
fi

if [ "$CLEAN" -eq 1 ]; then
  while IFS= read -r pkg; do
    [ -n "$pkg" ] && cargo clean -p "$pkg" >/dev/null 2>&1 || true
  done < <(cargo metadata --no-deps --format-version 1 2>/dev/null \
            | python3 -c 'import json,sys; [print(p["name"]) for p in json.load(sys.stdin)["packages"]]' 2>/dev/null || true)
fi

PYSRC=$(cat <<'PYEND'
import json, os, sys

fmt = os.environ["FORMAT"]
root = os.getcwd()
out, seen = [], set()

for line in sys.stdin:
    line = line.strip()
    if not line or not line.startswith("{"):
        continue
    try:
        rec = json.loads(line)
    except json.JSONDecodeError:
        continue
    if rec.get("reason") != "compiler-message":
        continue
    msg = rec.get("message") or {}
    level = msg.get("level")
    if level not in ("warning", "error"):
        continue                        # note/help are children of a parent
    code = (msg.get("code") or {}).get("code")
    if not code:
        continue                        # "N warnings emitted" summaries
    span = next((s for s in msg.get("spans", []) if s.get("is_primary")), None)
    if not span:
        continue
    path = span["file_name"]
    if os.path.isabs(path):
        if not path.startswith(root + os.sep):
            continue                    # dependency or OUT_DIR
        path = os.path.relpath(path, root)
    if path.startswith(("target/", "..")):
        continue
    line_no = span.get("line_start", 1)
    fp = f"{code}:{path}:{line_no}"
    if fp in seen:                      # --all-targets lints lib and lib-test
        continue
    seen.add(fp)
    out.append({
        "tool": "clippy", "rule": code, "level": level,
        "path": path, "line": line_no, "col": span.get("column_start", 1),
        "message": msg.get("message", ""), "fingerprint": fp,
    })

if fmt == "jsonl":
    for f in out:
        print(json.dumps(f, separators=(",", ":")))
else:
    for f in out:
        print(f"{f['path']}:{f['line']}:{f['col']}: {f['level']}: {f['rule']}: {f['message']}")

status = sys.stderr if fmt == "jsonl" else sys.stdout
errs = sum(1 for f in out if f["level"] == "error")
if not out:
    print("  ✓ clippy-findings: no diagnostics.", file=status)
else:
    print(f"\n  clippy-findings: {len(out)} diagnostic(s), {errs} error(s).", file=status)
PYEND
)

# shellcheck disable=SC2086  # PKG_ARGS/FEATURE_ARGS are intentionally word-split
{ cargo clippy --all-targets $PKG_ARGS $FEATURE_ARGS --message-format=json 2>/dev/null || true; } \
  | FORMAT="$FORMAT" python3 -c "$PYSRC"
