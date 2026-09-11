#!/usr/bin/env bash
# lints-check — assert the consumer's Cargo.toml carries the canonical lint
# block from rust-quality's lints.toml, and that every workspace member opts in.
#
# Cargo has no include mechanism for manifests, so the lint block cannot be
# copied in the way clippy.toml / rustfmt.toml / deny.toml are. This gate is the
# substitute: it reports drift, it never mutates. Adding a lint to the fleet
# means editing lints.toml here and letting this fail in every consumer until
# they catch up.
#
# Checks:
#   lint-missing   canonical lint absent from the consumer manifest
#   lint-drift     present but at a different level/priority
#   lints-opt-out  workspace member without `[lints] workspace = true`
#
# Usage:
#   bash scripts/lints-check.sh                # human report
#   bash scripts/lints-check.sh --format jsonl # structured findings
#   bash scripts/lints-check.sh --warn-only    # always exit 0
set -euo pipefail

FORMAT="text"
WARN_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --format)   FORMAT="${2:-}"; shift 2 ;;
    --format=*) FORMAT="${1#*=}"; shift ;;
    --warn-only) WARN_ONLY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

case "$FORMAT" in
  text|jsonl) ;;
  *) echo "lints-check: unknown --format '$FORMAT' (want text|jsonl)" >&2; exit 2 ;;
esac

CANONICAL="${CANONICAL:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lints.toml}"
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

CANONICAL="$CANONICAL" FORMAT="$FORMAT" WARN_ONLY="$WARN_ONLY" python3 - <<'PY'
import json, os, pathlib, subprocess, sys, tomllib

canonical = pathlib.Path(os.environ["CANONICAL"])
fmt = os.environ["FORMAT"]
warn_only = os.environ["WARN_ONLY"] == "1"
root = pathlib.Path(".")
manifest = root / "Cargo.toml"

def say(*a):
    print(*a, file=sys.stderr if fmt == "jsonl" else sys.stdout)

if not manifest.is_file():
    say("  lints-check: no Cargo.toml at the repo root — skipped.")
    sys.exit(0)

want = tomllib.loads(canonical.read_text()).get("workspace", {}).get("lints", {})
raw = manifest.read_text()
have_doc = tomllib.loads(raw)

# A workspace root keeps lints under [workspace.lints]; a standalone package
# under [lints]. Accept either — the rules are the same.
have = have_doc.get("workspace", {}).get("lints") or have_doc.get("lints") or {}
scope = "workspace.lints" if have_doc.get("workspace", {}).get("lints") else "lints"

# Line lookup so findings point somewhere useful instead of line 1.
lines = raw.splitlines()
def line_of(key):
    for i, l in enumerate(lines, 1):
        if l.strip().startswith(key + " "):
            return i
    return 1

findings = []
def add(rule, path, line, message, key=None):
    # `rule:path:line` alone is not unique here. A lint that is missing has no
    # line to point at, so `line_of` falls back to 1 and every `lint-missing`
    # in a run collides on `lint-missing:Cargo.toml:1` — dedup would keep one
    # and silently drop the rest. `key` is the lint name, which is what
    # actually distinguishes them and is stable across runs.
    fp = f"{rule}:{path}:{line}" + (f":{key}" if key else "")
    findings.append({
        "tool": "lints-check", "rule": rule, "level": "error",
        "path": path, "line": line, "message": message,
        "fingerprint": fp,
    })

for group, entries in want.items():
    got_group = have.get(group, {})
    for lint, level in entries.items():
        if lint not in got_group:
            add("lint-missing", "Cargo.toml", line_of(lint),
                f"[{scope}.{group}] is missing `{lint} = {json.dumps(level)}`",
                key=f"{group}.{lint}")
        elif got_group[lint] != level:
            add("lint-drift", "Cargo.toml", line_of(lint),
                f"[{scope}.{group}] {lint}: expected {json.dumps(level)}, "
                f"found {json.dumps(got_group[lint])}",
                key=f"{group}.{lint}")

# Every member of a workspace must opt in, or the block above applies to
# nothing.
#
# Ask cargo for the member list rather than globbing `workspace.members`.
# A glob answers a different question: cargo also makes every path dependency
# of a member an implicit member, honours `workspace.exclude`, and counts the
# root package itself. A crate reached only as a path dependency is a real
# member, inherits nothing, and a glob reports the workspace clean.
def cargo_members():
    out = subprocess.run(
        ["cargo", "metadata", "--no-deps", "--format-version", "1", "--offline"],
        capture_output=True, text=True)
    if out.returncode != 0:
        return None
    return [pathlib.Path(pkg["manifest_path"]) for pkg in json.loads(out.stdout)["packages"]]

seen = set()
if have_doc.get("workspace") is not None:
    manifests = cargo_members()
    if manifests is None:
        # Degraded, and it says so: a silent fall back to the weaker check is
        # the failure mode this whole script exists to catch.
        say("  ! lints-check: `cargo metadata` failed — falling back to the "
            "`members` glob, which cannot see implicit members.")
        manifests = [d / "Cargo.toml" for pat in have_doc["workspace"].get("members", [])
                     for d in sorted(root.glob(pat))]
    for m in sorted(manifests):
        if not m.is_file() or m in seen:
            continue
        seen.add(m)
        try:
            rel = m.relative_to(root.resolve())
        except ValueError:
            rel = m
        doc = tomllib.loads(m.read_text())
        if doc.get("lints", {}).get("workspace") is not True:
            add("lints-opt-out", str(rel), 1,
                "member does not inherit workspace lints — add `[lints]\\nworkspace = true`")

if fmt == "jsonl":
    for f in findings:
        print(json.dumps(f, separators=(",", ":")))

if not findings:
    say(f"  ✓ lints-check: [{scope}] matches rust-quality/lints.toml"
        f"{f', {len(seen)} member(s) opted in' if seen else ''}.")
    sys.exit(0)

if fmt == "text":
    for f in findings:
        print(f"{f['path']}:{f['line']}: {f['rule']}: {f['message']}")
say("")
say(f"  lints-check: {len(findings)} finding(s). "
    f"Reconcile against {canonical}.")
sys.exit(0 if warn_only else 1)
PY
