# pnpm sparse checkout: filtered re-resolve changes peer resolutions

In a cone-mode git sparse checkout, some workspace packages are listed in
`pnpm-workspace.yaml` but have no `package.json` on disk. A `.pnpmfile.mjs`
`updateConfig` hook sets `filter` to the workspace root (`.`) plus every
on-disk package. When pnpm has to re-resolve, `pnpm install --lockfile-only`
keeps every importer, including the off-disk one. But the lockfile it writes
still differs from the lockfile a full checkout writes for the same change:

- **Peer resolutions change.** `ws` resolves its optional peer `bufferutil`
  to a different version.
- **`optional: true` flags flip.** A snapshot that the off-disk package
  depends on directly is marked `optional: true`.

This is a follow-up to
[kirkobyte/pnpm-sparse-checkout-lockfile-repro](https://github.com/kirkobyte/pnpm-sparse-checkout-lockfile-repro).
That repro shows that without the filter, pnpm drops the off-disk importers
entirely. This repro covers the drift that remains **with** the filter.

## Setup

```
package.json            "packageManager": "pnpm@12.16.1", no dependencies
pnpm-workspace.yaml     packages/a, packages/b, packages/c (default settings)
.pnpmfile.mjs           updateConfig: filter = ["."] + names of on-disk packages
packages/a              ws@8.18.0         (optional peers: bufferutil, utf-8-validate)
packages/b              bufferutil@4.0.8
packages/c              bufferutil@4.0.9, utf-8-validate@6.0.5   <- off disk when sparse
pnpm-lock.yaml          written by `pnpm install --lockfile-only` in a full checkout
```

`ws` has no direct dependency on `bufferutil` or `utf-8-validate`. It lists
them as optional peers. In the full checkout, pnpm resolves those peers from
the versions other workspace projects use, so the committed lockfile has:

```yaml
packages/a:
  dependencies:
    ws:
      specifier: 8.18.0
      version: 8.18.0(bufferutil@4.0.9)(utf-8-validate@6.0.5)
```

`packages/c` is the only project that uses `bufferutil@4.0.9` and
`utf-8-validate@6.0.5`.

## Steps

```sh
git clone https://github.com/kirkobyte/pnpm-sparse-filter-drift-repro.git
cd pnpm-sparse-filter-drift-repro
./repro.sh
```

`repro.sh` does this. It only edits `.pnpmfile.mjs` and `pnpm-lock.yaml`,
and restores them from git between steps, so you can run it again:

1. **Full checkout:** append a comment to `.pnpmfile.mjs` (this changes
   `pnpmfileChecksum`, so pnpm must re-resolve), then run
   `pnpm install --lockfile-only`. It saves the result as `out/full.yaml`.
2. **Control:** full checkout with the same edit, but the hook also leaves
   `packages/c` out of the filter (`REPRO_EXCLUDE=packages/c`). This saves
   `out/control.yaml`.
3. **Sparse checkout:** run `git sparse-checkout init --cone` and
   `git sparse-checkout set packages/a packages/b`, so `packages/c` is off
   disk. Make the same edit and run the same command. This saves
   `out/sparse.yaml`.

It then compares steps 2 and 3 with step 1 and prints the diff.

## Expected

`out/sparse.yaml` is identical to `out/full.yaml`. The change and the
committed lockfile are the same, and the sparse checkout only hides
`packages/c` from disk. `packages/c` is still in the lockfile, which is the
whole point of the filter.

## Actual

```
pnpm 12.16.1 / node v24.14.1 / Darwin arm64 / git version 2.56.0

1. Full checkout: edit .pnpmfile.mjs, then pnpm install --lockfile-only
    Scope: all 4 workspace projects
2. Control: full checkout, packages/c on disk but left out of the filter
    Scope: 3 of 4 workspace projects
3. Sparse checkout (cone mode, packages/c off disk): same edit, same command
    on disk: a b  (packages/c is listed in pnpm-workspace.yaml)
    Scope: all 3 workspace projects

  control (filter only): SAME as full checkout
  sparse  (filter + c off disk): DIFFERS from full checkout (7 changed lines)

diff out/full.yaml out/sparse.yaml:
  175c175
  <         version: 8.18.0(bufferutil@4.0.9)(utf-8-validate@6.0.5)
  ---
  >         version: 8.18.0(bufferutil@4.0.8)(utf-8-validate@6.0.5)
  236a237
  >     optional: true
  238c239
  <   ws@8.18.0(bufferutil@4.0.9)(utf-8-validate@6.0.5):
  ---
  >   ws@8.18.0(bufferutil@4.0.8)(utf-8-validate@6.0.5):
  240c241
  <       bufferutil: 4.0.9
  ---
  >       bufferutil: 4.0.8

EXPECTED: the sparse-checkout lockfile is identical to the full-checkout lockfile.
ACTUAL:   it differs: peer suffixes on ws and optional flags on snapshots change.
```

In context, the sparse checkout writes:

```yaml
importers:
  packages/a:
    dependencies:
      ws:
        specifier: 8.18.0
        version: 8.18.0(bufferutil@4.0.8)(utf-8-validate@6.0.5)   # was bufferutil@4.0.9
  packages/c:                     # kept, with the same specifiers and versions
    dependencies:
      bufferutil: {specifier: 4.0.9, version: 4.0.9}
      utf-8-validate: {specifier: 6.0.5, version: 6.0.5}

snapshots:
  utf-8-validate@6.0.5:
    dependencies:
      node-gyp-build: 4.8.4
    optional: true                # new: packages/c depends on it directly
  ws@8.18.0(bufferutil@4.0.8)(utf-8-validate@6.0.5):              # was bufferutil@4.0.9
    optionalDependencies:
      bufferutil: 4.0.8
      utf-8-validate: 6.0.5
```

What the results show:

- **The filter alone is not the cause.** The control run filters out
  `packages/c` while it is on disk, and the result is identical to the full
  checkout. The drift only appears when `packages/c` is also off disk.
- **The off-disk importer is kept but its dependencies seem to be ignored.**
  `packages/c` stays in `importers` unchanged. But peer resolution no longer
  sees its `bufferutil@4.0.9`, so `ws` gets `bufferutil@4.0.8` from
  `packages/b`. And `utf-8-validate@6.0.5` is now only reachable through an
  optional peer, so it is marked `optional: true`, even though `packages/c`
  depends on it directly.
- **Workspace settings do not matter.** The result is the same with
  `autoInstallPeers: false`, `dedupePeers: true`, both, or neither.
  (`autoInstallPeers: false` and `dedupePeers: true` are what the real
  monorepo uses.) The repro uses the defaults.

## Why it matters

`pnpm-lock.yaml` is committed and shared by everyone who works in the
workspace. Developers who use sparse checkouts in a large monorepo will
re-resolve now and then (a pnpmfile edit, a catalog bump, a dependency added
to an on-disk package). Each time, they write a lockfile that differs from
what a full checkout or CI produces. That causes lockfile churn in their pull
requests and CI failures for "lockfile out of date". It can also change which
peer version a package is linked against for everyone else.

In the monorepo where this was found, one re-resolve in a sparse checkout
changed 15 importers and about 60 snapshots (668 diff lines). The changes hit
both on-disk and off-disk importers. Examples:

- vitest snapshots resolved against `vite@8.0.13` in place of `vite@8.3.4`
- `(@babel/core@7.29.7)` peer suffixes added or dropped on react-native,
  styled-components and storybook snapshots
- `'@isaacs/ttlcache@1.4.1': {}` became `optional: true`

This repro shows the same two kinds of change (a different peer version and
a flipped optional flag) with four small npm packages (`ws`, `bufferutil`,
`utf-8-validate`, `node-gyp-build`). It only shows drift on an on-disk
importer (`packages/a`). The monorepo also shows drift on off-disk
importers, which this repro does not cover.

## What I tried

- `packages/a` with `ws` and `packages/c` with `bufferutil` (no
  `packages/b`): only the `optional: true` flips reproduce
  (`bufferutil@4.0.9` and `node-gyp-build@4.8.4`). The peer suffix stays
  `bufferutil@4.0.9` because no other version exists.
- Adding `packages/b` with `bufferutil@4.0.8` gives a second candidate, and
  then the peer suffix changes too. `utf-8-validate` in `packages/c` adds the
  `optional: true` flip next to it.
- Moving `bufferutil@4.0.8` from `packages/b` to the root `package.json`
  only reproduces the `optional: true` flip on `utf-8-validate@6.0.5`. The
  peer suffix stays `bufferutil@4.0.9`. So the peer drift needs the competing
  version to come from another workspace package.

## Environment

- pnpm 12.16.1 (pinned with `packageManager`; `lockfileVersion: '9.0'`)
- Node v24.14.1
- macOS 27.2 (Apple Silicon, Darwin arm64)
- git 2.56.0, cone-mode sparse checkout
