#!/usr/bin/env bash
# findings.sh — the agent-facing view: every finding as one JSON object per
# line, in the shared fleet schema.
#
#   {"tool":..,"rule":..,"level":"error|warning|note","path":..,"line":N,
#    "col":N?,"message":..,"fingerprint":"rule:path:line"}
#
# This is the ONLY script that speaks JSON. gate.sh renders the same checks for
# humans from the same functions in lib.sh — the format lives at the edge, not
# duplicated across every emitter.
#
# A pure producer: it never re-gates and never aborts on a finding. Enforcement
# is gate.sh's job. Dedup across runs via `fingerprint`.
#
# Not for the pre-commit path: the clippy pass busts the clippy cache, because
# a warm `cargo clippy` prints nothing at all and a check that silently reports
# nothing is worse than no check.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
. "$HERE/lib.sh"

PKG_ARGS="${PKG_ARGS:---workspace}"
FEATURE_ARGS="${FEATURE_ARGS:---all-features}"
OUT="${1:-}"

# Gate the crate the caller is standing in. A consumer whose crates are not one
# workspace passes each by `dir`, which is a `cd` before this script runs -- and
# an unconditional jump to the git toplevel undoes it on line one, silently.
# That is not a theoretical failure: in a repo with no root manifest it made
# lints-check print "no Cargo.toml at the repo root -- skipped" and exit 0, a
# green light for a check that ran on nothing.
#
# Falling back to the toplevel keeps the convenience this always had: run it
# from anywhere in a single-crate repo and it finds the manifest.
if [ ! -f Cargo.toml ]; then
  cd "$(git rev-parse --show-toplevel)"
fi

emit() {  # stdin: lib.sh records -> stdout: JSONL
  python3 -c '
import json, sys
for raw in sys.stdin:
    parts = raw.rstrip("\n").split("\t")
    if len(parts) != 5:
        continue
    rule, level, path, line, message = parts
    print(json.dumps({
        "tool": "rq", "rule": rule, "level": level, "path": path,
        "line": int(line), "message": message,
        "fingerprint": f"{rule}:{path}:{line}",
    }, separators=(",", ":")))'
}

clippy_findings() {
  command -v cargo >/dev/null 2>&1 || return 0
  [ -f Cargo.toml ] || return 0
  # Clippy caches hard. Clean only the workspace packages — dependencies stay
  # warm, so this costs one workspace recompile, not a cold build.
  while IFS= read -r pkg; do
    [ -n "$pkg" ] && cargo clean -p "$pkg" >/dev/null 2>&1 || true
  done < <(cargo metadata --no-deps --format-version 1 2>/dev/null \
            | python3 -c 'import json,sys;[print(p["name"]) for p in json.load(sys.stdin)["packages"]]' 2>/dev/null || true)

  # shellcheck disable=SC2086
  { cargo clippy --all-targets $PKG_ARGS $FEATURE_ARGS --message-format=json 2>/dev/null || true; } \
    | python3 -c '
import json, os, sys
root, seen = os.getcwd(), set()
for raw in sys.stdin:
    raw = raw.strip()
    if not raw.startswith("{"):
        continue
    try:
        rec = json.loads(raw)
    except json.JSONDecodeError:
        continue
    if rec.get("reason") != "compiler-message":
        continue
    msg = rec.get("message") or {}
    if msg.get("level") not in ("warning", "error"):
        continue                                   # note/help are children
    code = (msg.get("code") or {}).get("code")
    if not code:
        continue                                   # "N warnings emitted" summaries
    span = next((s for s in msg.get("spans", []) if s.get("is_primary")), None)
    if not span:
        continue
    path = span["file_name"]
    if os.path.isabs(path):
        if not path.startswith(root + os.sep):
            continue                               # dependency or OUT_DIR
        path = os.path.relpath(path, root)
    if path.startswith(("target/", "..")):
        continue
    line = span.get("line_start", 1)
    fp = f"{code}:{path}:{line}"
    if fp in seen:                                 # --all-targets lints lib and lib-test
        continue
    seen.add(fp)
    print(json.dumps({
        "tool": "clippy", "rule": code, "level": msg["level"], "path": path,
        "line": line, "col": span.get("column_start", 1),
        "message": msg.get("message", ""), "fingerprint": fp,
    }, separators=(",", ":")))'
}

stream() {
  local files=()
  mapfile -t files < <(tracked_rs)   # mapfile, not $(..): paths may contain spaces
  clippy_findings
  emit < <(ai_lint "${files[@]+"${files[@]}"}"; god_files; dup_deps)
  bash "$HERE/lints-check.sh" --format jsonl --warn-only 2>/dev/null || true
}

if [ -n "$OUT" ]; then
  mkdir -p "$(dirname "$OUT")"
  stream > "$OUT"
  total=$(grep -c . "$OUT" 2>/dev/null || true)
  errs=$(grep -c '"level":"error"' "$OUT" 2>/dev/null || true)
  echo "findings: ${total:-0} total, ${errs:-0} error(s) -> $OUT" >&2
else
  stream
fi
