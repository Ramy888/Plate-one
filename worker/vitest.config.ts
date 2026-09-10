import { defineWorkersConfig, readD1Migrations } from '@cloudflare/vitest-pool-workers/config';
import path from 'node:path';

const migrations = await readD1Migrations(path.join(__dirname, 'migrations'));

export default defineWorkersConfig({
  test: {
    setupFiles: ['./test/setup.ts'],
    poolOptions: {
      workers: {
        singleWorker: true,
        // Miniflare's per-test storage snapshots fail against R2. Every suite
        // clears its own tables and the bucket in beforeEach, so isolation is
        // explicit rather than magic.
        isolatedStorage: false,
        wrangler: { configPath: './wrangler.jsonc' },
        miniflare: {
          // Handed to the setup file, which applies them before each test.
          bindings: { TEST_MIGRATIONS: migrations },
        },
      },
    },
  },
});
