#!/usr/bin/env bash
# check-tools — report which gate tools are present and exit non-zero when any
# are missing.
#
# Narrow on purpose: install-tools.sh is the remediation, this is the diagnosis.
set -euo pipefail

cargo_bin="${CARGO_HOME:-$HOME/.cargo}/bin"
missing=0

have() {
  command -v "$1" >/dev/null 2>&1 || [ -x "$cargo_bin/$1" ]
}

for tool in cargo rustc cargo-clippy rustfmt \
            cargo-nextest cargo-deny cargo-machete \
            cargo-llvm-cov cargo-semver-checks cargo-hack; do
  if have "$tool"; then
    printf "  ✓ %s\n" "$tool"
  else
    printf "  ✗ %s — MISSING\n" "$tool"
    missing=$((missing + 1))
  fi
done

if [ "$missing" -gt 0 ]; then
  echo
  echo "$missing tool(s) missing. Run: scripts/install-tools.sh"
  exit 1
fi
