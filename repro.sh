#!/usr/bin/env bash
#
# Runs the steps from README.md in two temporary clones of this repository
# (a full checkout and a sparse checkout) and prints the lockfile diff each
# one produces. Your own checkout is not modified.
#
# Usage: ./repro.sh
# Needs git, node, and pnpm 12.16.1 (see "packageManager" in package.json).

set -euo pipefail
cd "$(dirname "$0")"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

run() {
  # run <name> [sparse-checkout dirs...]
  local name=$1 dir="$TMP/$1"
  shift
  git clone -q "$PWD" "$dir"
  if [[ $# -gt 0 ]]; then
    git -C "$dir" sparse-checkout set --cone "$@"
  fi
  echo "== $name checkout (packages on disk: $(ls "$dir/packages" | paste -sd' ' -))"
  echo "\$ (cd packages/a && pnpm pkg set dependencies.postcss-load-config=6.0.1)"
  (cd "$dir/packages/a" && pnpm pkg set dependencies.postcss-load-config=6.0.1)
  echo "\$ pnpm install --filter @repro/a --filter @repro/b"
  (cd "$dir" && pnpm install --filter @repro/a --filter @repro/b >/dev/null)
  git -C "$dir" --no-pager diff -- pnpm-lock.yaml
  echo
}

echo "pnpm $(pnpm --version) / node $(node --version) / $(uname -sm) / $(git --version)"
echo
run full
run sparse packages/a packages/b

echo "== full vs sparse lockfile"
diff "$TMP/full/pnpm-lock.yaml" "$TMP/sparse/pnpm-lock.yaml" || true
echo
echo "EXPECTED: both checkouts write the same pnpm-lock.yaml."
if cmp -s "$TMP/full/pnpm-lock.yaml" "$TMP/sparse/pnpm-lock.yaml"; then
  echo "ACTUAL:   they are the same (the issue did not reproduce)."
else
  echo "ACTUAL:   the sparse checkout resolves the yaml peer to 2.8.0 (not 2.9.0) and marks jiti optional."
fi
