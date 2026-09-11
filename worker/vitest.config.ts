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
          bindings: {
            // Handed to the setup file, which applies them before each test.
            TEST_MIGRATIONS: migrations,
            // Deliberately fake, and deliberately overriding whatever is in
            // .dev.vars. A test run must not depend on a real key existing, and
            // the assertion that the key never reaches the client is only
            // meaningful against a value the test controls.
            ASSEMBLYAI_API_KEY: 'test-assemblyai-key-not-real',
            GEMINI_API_KEY: 'test-gemini-key-not-real',
            // The audience every test token is minted for. Deliberately not a
            // real client id: the check that matters is that a token for some
            // *other* audience is refused, and that is only meaningful against
            // a value the test controls.
            GOOGLE_CLIENT_ID: 'test-client-id.apps.googleusercontent.com',
          },
        },
      },
    },
  },
});
