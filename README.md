# pnpm sparse checkout: filtered re-resolve changes peer resolutions

In a cone-mode git sparse checkout, a workspace package can be listed in
`pnpm-workspace.yaml` but have no `package.json` on disk. If you re-resolve
with `--filter` set to the on-disk packages, pnpm keeps the off-disk importer
in `pnpm-lock.yaml`. But it writes a different lockfile than a full checkout
does for the same command:

- **A peer resolution changes:** `ws@8.18.0(bufferutil@4.0.9)` becomes
  `ws@8.18.0(bufferutil@4.0.8)`.
- **An `optional: true` flag is added** to `utf-8-validate@6.0.5`, which the
  off-disk package depends on directly.

This is a follow-up to
[kirkobyte/pnpm-sparse-checkout-lockfile-repro](https://github.com/kirkobyte/pnpm-sparse-checkout-lockfile-repro).
That repro shows that without `--filter`, pnpm drops the off-disk importer
entirely. This one covers the drift that remains **with** `--filter`.

## The workspace

| Package      | Dependencies                             |
| ------------ | ---------------------------------------- |
| `packages/a` | `ws@8.18.0` (optional peers: `bufferutil`, `utf-8-validate`) |
| `packages/b` | `bufferutil@4.0.8`                       |
| `packages/c` | `bufferutil@4.0.9`, `utf-8-validate@6.0.5` |

The root `package.json` pins `pnpm@12.16.1` with `packageManager`.
`pnpm-workspace.yaml` lists all three packages and uses default settings.
`pnpm-lock.yaml` was written by `pnpm install --lockfile-only` in a full
checkout.

## Reproduce

### With the script

```sh
git clone https://github.com/kirkobyte/pnpm-sparse-filter-drift-repro.git
cd pnpm-sparse-filter-drift-repro
./repro.sh
```

The script runs the steps below in two temporary clones (a full checkout and
a sparse checkout) and prints the lockfile diff for each. It does not change
your clone.

### By hand

1. Clone the repo and make a cone-mode sparse checkout that leaves
   `packages/c` off disk:

   ```sh
   git clone https://github.com/kirkobyte/pnpm-sparse-filter-drift-repro.git
   cd pnpm-sparse-filter-drift-repro
   git sparse-checkout set --cone packages/a packages/b
   ```

2. Re-resolve, filtered to the on-disk packages:

   ```sh
   pnpm install --lockfile-only --fix-lockfile --filter @repro/a --filter @repro/b
   ```

3. Look at the result:

   ```sh
   git diff pnpm-lock.yaml
   ```

To compare, run step 2 in a full checkout (skip step 1). `pnpm-lock.yaml` is
unchanged.

## Expected

`pnpm-lock.yaml` is unchanged, the same as in a full checkout. Nothing in the
workspace changed. The sparse checkout only hides `packages/c` from disk, and
`packages/c` is still in the lockfile.

## Actual

```diff
@@ -170,7 +170,7 @@ importers:
     dependencies:
       ws:
         specifier: 8.18.0
-        version: 8.18.0(bufferutil@4.0.9)(utf-8-validate@6.0.5)
+        version: 8.18.0(bufferutil@4.0.8)(utf-8-validate@6.0.5)
 
   packages/b:
     dependencies:
@@ -232,8 +232,9 @@ snapshots:
   utf-8-validate@6.0.5:
     dependencies:
       node-gyp-build: 4.8.4
+    optional: true
 
-  ws@8.18.0(bufferutil@4.0.9)(utf-8-validate@6.0.5):
+  ws@8.18.0(bufferutil@4.0.8)(utf-8-validate@6.0.5):
     optionalDependencies:
-      bufferutil: 4.0.9
+      bufferutil: 4.0.8
       utf-8-validate: 6.0.5
```

The `packages/c` importer stays in the lockfile unchanged. But pnpm seems to
ignore its dependencies when it resolves peers and works out optional flags:

- `ws` now takes its optional peer `bufferutil` from `packages/b` (4.0.8),
  not `packages/c` (4.0.9).
- `utf-8-validate@6.0.5` is now only reachable through an optional peer, so it
  is marked `optional: true`, even though `packages/c` depends on it directly.

## Notes

- **Other triggers.** Without `--fix-lockfile`, the command in step 2 sees an
  up-to-date lockfile and does nothing. Any change that makes pnpm re-resolve
  gives the same drift. For example, `pnpm --filter @repro/a add
  is-number@7.0.0 --lockfile-only` in the sparse checkout writes the same peer
  and `optional` changes as well as adding `is-number`.
- **The filter source does not matter.** A `.pnpmfile.mjs` `updateConfig`
  hook that returns the same `filter` gives the same result.
- **The filter alone is not the cause.** In a full checkout, the same
  command (with `packages/c` on disk but left out of the filter) leaves the
  lockfile unchanged.
- **The sparse checkout itself is not needed.** Deleting `packages/c` from a
  full checkout (`rm -rf packages/c`) gives the same drift. What matters is
  that the package's `package.json` is missing.
- **Workspace settings do not matter.** The result is the same with
  `autoInstallPeers: false` and `dedupePeers: true`.
- **Without `--filter`, the result is worse.** pnpm drops the `packages/c`
  importer and its packages, as in the earlier repro.
- **`packages/b` is needed for the peer drift.** Without a second
  `bufferutil` version in another workspace package, only the
  `optional: true` flags change.

## Why it matters

`pnpm-lock.yaml` is committed and shared by everyone who works in the
workspace. Developers who use sparse checkouts in a large monorepo re-resolve
now and then, for example when they add a dependency to a package they have
on disk. Each time, they write a lockfile that differs from what a full
checkout or CI produces. That causes lockfile churn in their pull requests
and "lockfile out of date" failures in CI. It can also change which peer
version a package is linked against for everyone else.

In the monorepo where this was found, one re-resolve in a sparse checkout
changed 15 importers and about 60 snapshots (668 diff lines), on both on-disk
and off-disk importers. Examples:

- vitest snapshots resolved against `vite@8.0.13` in place of `vite@8.3.4`
- `(@babel/core@7.29.7)` peer suffixes added or dropped on react-native,
  styled-components and storybook snapshots
- `'@isaacs/ttlcache@1.4.1': {}` became `optional: true`

This repro only shows drift on an on-disk importer (`packages/a`). It does
not reproduce the drift on off-disk importers seen in the monorepo.

## Environment

- pnpm 12.16.1 (pinned with `packageManager`; `lockfileVersion: '9.0'`)
- Node v24.14.1
- macOS 27.2 (Apple Silicon, Darwin arm64)
- git 2.56.0
