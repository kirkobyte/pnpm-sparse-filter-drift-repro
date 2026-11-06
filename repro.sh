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

INSTALL=(pnpm install --lockfile-only --fix-lockfile --filter @repro/a --filter @repro/b)
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
  echo "\$ ${INSTALL[*]}"
  (cd "$dir" && "${INSTALL[@]}" >/dev/null)
  if git -C "$dir" diff --quiet -- pnpm-lock.yaml; then
    echo "pnpm-lock.yaml: unchanged"
  else
    git -C "$dir" --no-pager diff -- pnpm-lock.yaml
  fi
  echo
}

echo "pnpm $(pnpm --version) / node $(node --version) / $(uname -sm) / $(git --version)"
echo
run full
run sparse packages/a packages/b

echo "EXPECTED: pnpm-lock.yaml is unchanged in both checkouts."
if git -C "$TMP/sparse" diff --quiet -- pnpm-lock.yaml; then
  echo "ACTUAL:   unchanged in both (the issue did not reproduce)."
else
  echo "ACTUAL:   the sparse checkout changes the ws peer resolution and adds optional: true."
fi
