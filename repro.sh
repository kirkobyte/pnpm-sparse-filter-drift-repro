#!/usr/bin/env bash
#
# Reproduces: in a cone-mode sparse checkout that keeps packages/c off disk,
# `pnpm install --lockfile-only` with an updateConfig filter of "." plus the
# on-disk packages keeps every importer, but still writes a lockfile that
# differs from the one a full checkout writes for the same change:
#   - a peer dependency suffix changes: ws@8.18.0(bufferutil@4.0.9) becomes
#     ws@8.18.0(bufferutil@4.0.8)
#   - a snapshot gains `optional: true` (utf-8-validate@6.0.5)
#
# The triggering change is an edit to .pnpmfile.mjs. That changes
# pnpmfileChecksum, so pnpm must re-resolve.
#
# Run from a clean clone of this repository:  ./repro.sh
# Needs git, node, and pnpm 12.16.1 (see "packageManager" in package.json).
# The script only modifies .pnpmfile.mjs and pnpm-lock.yaml, and restores them
# from git before and after each step. You can run it again at any time.

set -euo pipefail
cd "$(dirname "$0")"

OUT=out
mkdir -p "$OUT"

# Files this script edits. Only these are restored between steps.
TOUCHED=(.pnpmfile.mjs pnpm-lock.yaml)

if [[ -n "$(git status --porcelain -- "${TOUCHED[@]}")" && "${FORCE:-}" != 1 ]]; then
  echo "${TOUCHED[*]} have uncommitted changes. repro.sh restores them from git." >&2
  echo "Commit or stash them first, or run with FORCE=1." >&2
  exit 1
fi

reset() {
  git sparse-checkout disable >/dev/null 2>&1 || true
  git checkout -q -- "${TOUCHED[@]}"
}

# The triggering change. Any edit to the pnpmfile changes pnpmfileChecksum.
pnpmfile_change() { echo "// checksum change" >>.pnpmfile.mjs; }

install_lo() {
  pnpm install --lockfile-only 2>&1 | grep -E '^Scope|^Done' | sed 's/^/    /'
}

compare() {
  # compare <name> <file>: diff a lockfile against the full-checkout one.
  if cmp -s "$OUT/full.yaml" "$2"; then
    echo "  $1: SAME as full checkout"
  else
    echo "  $1: DIFFERS from full checkout ($(diff "$OUT/full.yaml" "$2" | grep -c '^[<>]') changed lines)"
  fi
}

reset
echo "pnpm $(pnpm --version) / node $(node --version) / $(uname -sm) / $(git --version)"
echo

echo "1. Full checkout: edit .pnpmfile.mjs, then pnpm install --lockfile-only"
pnpmfile_change
install_lo
cp pnpm-lock.yaml "$OUT/full.yaml"
reset

echo "2. Control: full checkout, packages/c on disk but left out of the filter"
pnpmfile_change
REPRO_EXCLUDE=packages/c install_lo
cp pnpm-lock.yaml "$OUT/control.yaml"
reset

echo "3. Sparse checkout (cone mode, packages/c off disk): same edit, same command"
git sparse-checkout init --cone >/dev/null
git sparse-checkout set packages/a packages/b >/dev/null
echo "    on disk: $(ls packages | paste -sd' ' -)  (packages/c is listed in pnpm-workspace.yaml)"
pnpmfile_change
install_lo
cp pnpm-lock.yaml "$OUT/sparse.yaml"
reset

echo
compare "control (filter only)" "$OUT/control.yaml"
compare "sparse  (filter + c off disk)" "$OUT/sparse.yaml"
echo
echo "diff $OUT/full.yaml $OUT/sparse.yaml:"
diff "$OUT/full.yaml" "$OUT/sparse.yaml" | sed 's/^/  /' || true
echo
echo "EXPECTED: the sparse-checkout lockfile is identical to the full-checkout lockfile."
if cmp -s "$OUT/full.yaml" "$OUT/sparse.yaml"; then
  echo "ACTUAL:   identical (the issue did not reproduce)."
else
  echo "ACTUAL:   it differs: peer suffixes on ws and optional flags on snapshots change."
fi
