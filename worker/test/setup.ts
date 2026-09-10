import { applyD1Migrations, createExecutionContext, env, waitOnExecutionContext } from 'cloudflare:test';
import { beforeAll } from 'vitest';

import worker from '../src/index';

declare module 'cloudflare:test' {
  interface ProvidedEnv extends Env {
    TEST_MIGRATIONS: D1Migration[];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);

  // The first request that touches a Durable Object after the pool loads the
  // module is rejected with "…changed, invalidating this Durable Object". It is
  // a one-off, and without this it lands on whichever test happens to run
  // first — a failure that has nothing to do with that test. Take the hit here
  // instead, where it belongs to nobody.
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const ctx = createExecutionContext();
      await worker.fetch(new Request('https://warmup.invalid/health'), env, ctx);
      await waitOnExecutionContext(ctx);
      return;
    } catch (error) {
      if (!String(error).includes('invalidating this Durable Object')) throw error;
    }
  }
});
