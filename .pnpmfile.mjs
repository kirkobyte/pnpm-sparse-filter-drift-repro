// Scope pnpm to the workspace root plus every workspace package that has a
// package.json on disk. In a full checkout that is every package. In a sparse
// checkout it leaves out the packages that git keeps off disk.
//
// REPRO_EXCLUDE (comma-separated directories) is only for the control run in
// repro.sh: it leaves a package out of the filter even though it is on disk.
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const exclude = (process.env.REPRO_EXCLUDE ?? '').split(',').filter(Boolean);

export const hooks = {
  updateConfig(config) {
    const dirs = readFileSync('pnpm-workspace.yaml', 'utf8')
      .split('\n')
      .map((line) => line.match(/^\s+-\s+(\S+)/)?.[1])
      .filter(Boolean);
    const filter = ['.'];
    for (const dir of dirs) {
      const manifest = join(dir, 'package.json');
      if (existsSync(manifest) && !exclude.includes(dir)) {
        filter.push(JSON.parse(readFileSync(manifest, 'utf8')).name);
      }
    }
    return { ...config, filter };
  },
};
