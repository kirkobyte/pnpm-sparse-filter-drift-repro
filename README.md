# pnpm sparse checkout: filtered install changes peer resolutions

In a cone-mode git sparse checkout, a workspace package can be listed in
`pnpm-workspace.yaml` but have no `package.json` on disk. If you change a
dependency in an on-disk package and run `pnpm install` with `--filter` set
to the on-disk packages, pnpm keeps the off-disk importer in
`pnpm-lock.yaml`. But it writes a different lockfile than a full checkout
does for the same change:

- **A peer resolution changes:** `postcss-load-config` resolves its optional
  peer `yaml` to 2.8.0 in place of 2.9.0.
- **An `optional: true` flag is added** to `jiti@2.6.0`, which the off-disk
  package depends on directly.

This is a follow-up to
[kirkobyte/pnpm-sparse-checkout-lockfile-repro](https://github.com/kirkobyte/pnpm-sparse-checkout-lockfile-repro).
That repro shows that without `--filter`, pnpm drops the off-disk importer
entirely. This one covers the drift that remains **with** `--filter`.

## The workspace

| Package      | Dependencies |
| ------------ | ------------ |
| `packages/a` | `postcss-load-config@6.0.0` (optional peers include `jiti` and `yaml`) |
| `packages/b` | `yaml@2.8.0` |
| `packages/c` | `jiti@2.6.0`, `yaml@2.9.0` |

The root `package.json` pins `pnpm@12.16.1` with `packageManager`.
`pnpm-workspace.yaml` lists all three packages and uses default settings.
`pnpm-lock.yaml` was written in a full checkout, where pnpm resolves the
optional peers of `postcss-load-config` from `packages/c`:

```yaml
packages/a:
  dependencies:
    postcss-load-config:
      specifier: 6.0.0
      version: 6.0.0(jiti@2.6.0)(yaml@2.9.0)
```

## Reproduce

### With the script

```sh
git clone https://github.com/kirkobyte/pnpm-sparse-filter-drift-repro.git
cd pnpm-sparse-filter-drift-repro
./repro.sh
```

The script runs the steps below in a full checkout and in a sparse checkout,
each in a temporary clone, and prints both lockfile diffs. It does not change
your clone.

### By hand

1. Clone the repo and make a cone-mode sparse checkout that leaves
   `packages/c` off disk:

   ```sh
   git clone https://github.com/kirkobyte/pnpm-sparse-filter-drift-repro.git
   cd pnpm-sparse-filter-drift-repro
   git sparse-checkout set --cone packages/a packages/b
   ```

2. In `packages/a/package.json`, change `postcss-load-config` from `6.0.0`
   to `6.0.1`. You can edit the file or run:

   ```sh
   (cd packages/a && pnpm pkg set dependencies.postcss-load-config=6.0.1)
   ```

3. Install, filtered to the on-disk packages:

   ```sh
   pnpm install --filter @repro/a --filter @repro/b
   ```

4. Look at the result:

   ```sh
   git diff pnpm-lock.yaml
   ```

To compare, do steps 2 to 4 in a full checkout (skip the `git
sparse-checkout` command).

## Expected

The only lockfile change is the `postcss-load-config` bump, the same as in a
full checkout:

```diff
       postcss-load-config:
-        specifier: 6.0.0
-        version: 6.0.0(jiti@2.6.0)(yaml@2.9.0)
+        specifier: 6.0.1
+        version: 6.0.1(jiti@2.6.0)(yaml@2.9.0)
 ...
-  postcss-load-config@6.0.0:
+  postcss-load-config@6.0.1:
 ...
-  postcss-load-config@6.0.0(jiti@2.6.0)(yaml@2.9.0):
+  postcss-load-config@6.0.1(jiti@2.6.0)(yaml@2.9.0):
```

## Actual

The sparse checkout also changes the `yaml` peer and adds `optional: true`
to `jiti`. Here is the difference between the full-checkout and sparse-checkout
lockfiles after the same change:

```diff
-        version: 6.0.1(jiti@2.6.0)(yaml@2.9.0)
+        version: 6.0.1(jiti@2.6.0)(yaml@2.8.0)
 ...
-  jiti@2.6.0: {}
+  jiti@2.6.0:
+    optional: true
 ...
-  postcss-load-config@6.0.1(jiti@2.6.0)(yaml@2.9.0):
+  postcss-load-config@6.0.1(jiti@2.6.0)(yaml@2.8.0):
     dependencies:
       lilconfig: 3.1.4
     optionalDependencies:
       jiti: 2.6.0
-      yaml: 2.9.0
+      yaml: 2.8.0
```

The `packages/c` importer stays in the lockfile unchanged. But pnpm seems to
ignore its dependencies when it resolves peers and works out optional flags:

- `postcss-load-config` now takes its optional peer `yaml` from `packages/b`
  (2.8.0), not from `packages/c` (2.9.0).
- `jiti@2.6.0` is now only reachable through an optional peer, so it is
  marked `optional: true`, even though `packages/c` depends on it directly.

## Notes

- **A change is needed.** Without step 2, the filtered install sees an
  up-to-date lockfile and does nothing. Any change that makes pnpm
  re-resolve gives the same drift. With no change at all,
  `pnpm install --fix-lockfile --filter @repro/a --filter @repro/b` also
  reproduces it.
- **The filter alone is not the cause.** In a full checkout, the same filter
  leaves `packages/c` out of the install, and the lockfile only shows the
  bump.
- **The filter source does not matter.** A `.pnpmfile.mjs` `updateConfig`
  hook that returns the same `filter` gives the same result.
- **The sparse checkout itself is not needed.** Deleting `packages/c` from a
  full checkout (`rm -rf packages/c`) gives the same drift. What matters is
  that the package's `package.json` is missing.
- **Workspace settings do not matter.** The result is the same with
  `autoInstallPeers: false` and `dedupePeers: true`.
- **Without `--filter`, the result is worse.** pnpm drops the `packages/c`
  importer and its packages, as in the earlier repro.
- **`packages/b` is needed for the peer drift.** Without a second `yaml`
  version in another workspace package, only the `optional: true` flags
  change (on `jiti@2.6.0` and `yaml@2.9.0`).

## Why it matters

`pnpm-lock.yaml` is committed and shared by everyone who works in the
workspace. Developers who use sparse checkouts in a large monorepo change
dependencies in the packages they have on disk. Each time, they write a
lockfile that differs from what a full checkout or CI produces. That causes
lockfile churn in their pull requests and "lockfile out of date" failures in
CI. It can also change which peer version a package is linked against for
everyone else.

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
