import {
  createExecutionContext,
  env,
  fetchMock,
  runInDurableObject,
  waitOnExecutionContext,
} from 'cloudflare:test';
import { afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import worker from '../src/index';
import { globalCap, quotaForDevice, resetVoiceCap, voiceCap } from './helpers';
import type { GlobalCap, QuotaCounter } from '../src/quota';

const BASE = 'https://api.plateone.app';
const AGENTS = 'https://agents.assemblyai.com';

let ipCounter = 0;

function send(path: string, { token, ip }: { token?: string; ip?: string } = {}): Promise<Response> {
  const headers: Record<string, string> = {
    'cf-connecting-ip': ip ?? `10.20.${Math.floor(++ipCounter / 250)}.${ipCounter % 250}`,
  };
  if (token) headers.authorization = `Bearer ${token}`;
  const ctx = createExecutionContext();
  return worker
    .fetch(new Request(`${BASE}${path}`, { method: 'POST', headers }), env, ctx)
    .then(async (response) => {
      await waitOnExecutionContext(ctx);
      return response;
    });
}

function interceptToken(reply: object, status = 200, times = 1) {
  fetchMock
    .get(AGENTS)
    .intercept({ path: (p) => p.startsWith('/v1/token'), method: 'GET' })
    .reply(status, reply)
    .times(times);
}

async function register(): Promise<string> {
  const ctx = createExecutionContext();
  const response = await worker.fetch(
    new Request(`${BASE}/v1/device`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'cf-connecting-ip': `10.21.${Math.floor(++ipCounter / 250)}.${ipCounter % 250}`,
      },
      body: JSON.stringify({ platform: 'web' }),
    }),
    env,
    ctx,
  );
  await waitOnExecutionContext(ctx);
  return ((await response.json()) as { deviceToken: string }).deviceToken;
}

beforeAll(() => {
  fetchMock.activate();
  // Anything not explicitly intercepted should fail loudly rather than silently
  // reach the real, paid API from a test run.
  fetchMock.disableNetConnect();
});

beforeEach(async () => {
  // Thirty conversations is the whole deployment's day. Without this the suite
  // spends it on itself and every file that runs after gets a 429.
  await resetVoiceCap();
  await env.DB.batch([
    env.DB.prepare('DELETE FROM scan_events'),
    env.DB.prepare('DELETE FROM devices'),
    env.DB.prepare('DELETE FROM rate_limits'),
  ]);
});

afterEach(() => fetchMock.assertNoPendingInterceptors());

describe('minting a voice token', () => {
  it('returns a token, its expiry and the session ceiling', async () => {
    interceptToken({ token: 'aai_temp_abc' });
    const deviceToken = await register();

    const response = await send('/v1/voice/token', { token: deviceToken });
    expect(response.status).toBe(200);

    const body = (await response.json()) as {
      token: string;
      expiresAt: number;
      maxSessionSeconds: number;
      quota: { voice: number };
    };
    expect(body.token).toBe('aai_temp_abc');
    expect(body.expiresAt).toBeGreaterThan(Math.floor(Date.now() / 1000));
    // Three hours is AssemblyAI's default; a tab left open must not bill for
    // it. This is also the number the day's budget multiplies by — the audio
    // never comes through the Worker, so nothing downstream of here can bound
    // what a conversation costs.
    expect(body.maxSessionSeconds).toBeLessThanOrEqual(180);
    expect(body.quota.voice).toBe(Number(env.VOICE_SESSIONS_PER_DAY) - 1);
  });

  it('never puts the API key in the response', async () => {
    interceptToken({ token: 'aai_temp_abc' });
    const deviceToken = await register();

    const response = await send('/v1/voice/token', { token: deviceToken });
    const raw = await response.text();

    // The whole reason this route exists. Asserted against the body *and* the
    // headers, because a key leaks the same either way.
    expect(raw).not.toContain(env.ASSEMBLYAI_API_KEY);
    expect(JSON.stringify([...response.headers])).not.toContain(env.ASSEMBLYAI_API_KEY);
  });

  it('sends the key upstream with the Bearer prefix this product requires', async () => {
    let seen: string | undefined;
    fetchMock
      .get(AGENTS)
      .intercept({
        path: (p) => p.startsWith('/v1/token'),
        method: 'GET',
      })
      .reply(200, (opts) => {
        seen = new Headers(opts.headers as HeadersInit).get('authorization') ?? undefined;
        return { token: 'aai_temp_abc' };
      });

    const deviceToken = await register();
    await send('/v1/voice/token', { token: deviceToken });

    // AssemblyAI's other products take the raw key. This one does not, and
    // getting it wrong fails at connect time rather than here.
    expect(seen).toBe(`Bearer ${env.ASSEMBLYAI_API_KEY}`);
  });

  it('needs a registered device', async () => {
    expect((await send('/v1/voice/token')).status).toBe(401);
    expect((await send('/v1/voice/token', { token: 'nonsense' })).status).toBe(401);
  });
});

describe('what it costs', () => {
  it('spends one voice session per token', async () => {
    interceptToken({ token: 'aai_temp_abc' });
    const deviceToken = await register();
    await send('/v1/voice/token', { token: deviceToken });

    const stub = await quotaForDevice(deviceToken);
    await runInDurableObject(stub, async (instance: QuotaCounter) => {
      const quota = await instance.peek(Math.floor(Date.now() / 1000));
      expect(quota.voice).toBe(Number(env.VOICE_SESSIONS_PER_DAY) - 1);
      // A conversation is not a meal scan and not a picture.
      expect(quota.previews).toBe(Number(env.PREVIEWS_PER_DAY));
      expect(quota.previews).toBe(Number(env.PREVIEWS_PER_DAY));
    });
  });

  it('refuses once the day’s conversations are gone, without calling AssemblyAI', async () => {
    // No interceptor: reaching the real API fails against disableNetConnect.
    const deviceToken = await register();
    const stub = await quotaForDevice(deviceToken);
    await runInDurableObject(stub, async (instance: QuotaCounter) => {
      const t = Math.floor(Date.now() / 1000);
      const limit = Number(env.VOICE_SESSIONS_PER_DAY);
      for (let i = 0; i < limit; i++) await instance.spend('voice', t);
    });

    const response = await send('/v1/voice/token', { token: deviceToken });
    expect(response.status).toBe(402);
    expect((await response.json() as { error: string }).error).toBe('quota_exhausted');
  });

  it('gives the session back when AssemblyAI refuses', async () => {
    interceptToken({ error: 'nope' }, 500);
    const deviceToken = await register();

    const response = await send('/v1/voice/token', { token: deviceToken });
    expect(response.status).toBe(503);

    const stub = await quotaForDevice(deviceToken);
    await runInDurableObject(stub, async (instance: QuotaCounter) => {
      // The user should not pay for our failure.
      expect((await instance.peek(Math.floor(Date.now() / 1000))).voice).toBe(
        Number(env.VOICE_SESSIONS_PER_DAY),
      );
    });
  });

  it('says nothing about the upstream failure', async () => {
    interceptToken({ error: 'invalid api key', detail: 'sk-secret-shaped' }, 401);
    const deviceToken = await register();

    const raw = await (await send('/v1/voice/token', { token: deviceToken })).text();
    expect(raw).not.toContain('invalid api key');
    expect(raw).not.toContain('sk-secret-shaped');
    expect(raw).toContain('Try again shortly');
  });

  it('refuses when the deployment’s budget is gone', async () => {
    const deviceToken = await register();
    const t = Math.floor(Date.now() / 1000);
    try {
      await runInDurableObject(globalCap(), async (instance) => {
        let last = await instance.spend(t);
        while (last.ok) last = await instance.spend(t);
      });

      const response = await send('/v1/voice/token', { token: deviceToken });
      expect(response.status).toBe(429);
      expect((await response.json() as { error: string }).error).toBe('service_busy');
    } finally {
      // Shared across every suite in the run — storage isolation is off — so
      // this belongs in `finally`, not at the end of the happy path.
      await runInDurableObject(globalCap(), async (_instance, state) => {
        await state.storage.deleteAll();
      });
    }
  });
})

describe('the free try gates the microphone', () => {
  it('refuses to mint a token when today\'s plate is used', async () => {
    // Better said at the microphone than three minutes in, when somebody has
    // described their dinner to nothing.
    const token = await register();
    await runInDurableObject(await quotaForDevice(token), async (q: QuotaCounter) => {
      const t = Math.floor(Date.now() / 1000);
      const limit = Number(env.PLATES_PER_DAY);
      for (let i = 0; i < limit; i++) await q.spend('plate', t);
    });

    // No interceptor: reaching AssemblyAI here fails against
    // disableNetConnect rather than passing quietly.
    const response = await send('/v1/voice/token', { token });

    expect(response.status).toBe(402);
    const body = (await response.json()) as { error: string; message: string };
    expect(body.error).toBe('try_used');
    expect(body.message).toContain('promo code');
  });

  it('does not spend a conversation on a refusal', async () => {
    const token = await register();
    await runInDurableObject(await quotaForDevice(token), async (q: QuotaCounter) => {
      const t = Math.floor(Date.now() / 1000);
      const limit = Number(env.PLATES_PER_DAY);
      for (let i = 0; i < limit; i++) await q.spend('plate', t);
    });

    const before = await runInDurableObject(
      await quotaForDevice(token),
      (q: QuotaCounter) => q.peek(Math.floor(Date.now() / 1000)),
    );
    await send('/v1/voice/token', { token });
    const after = await runInDurableObject(
      await quotaForDevice(token),
      (q: QuotaCounter) => q.peek(Math.floor(Date.now() / 1000)),
    );

    expect(after.voice).toBe(before.voice);
  });
});

describe('the deployment’s voice budget', () => {
  const limit = () => Number(env.GLOBAL_VOICE_SESSIONS_PER_DAY);
  const used = async () =>
    (await runInDurableObject(voiceCap(), (cap: GlobalCap) =>
      cap.peek(Math.floor(Date.now() / 1000), limit()))).used;

  it('refuses everyone once the day’s conversations are gone', async () => {
    // This is the number that stands between a public demo URL and an empty
    // credit balance: the Worker never sees how long a conversation ran, so
    // sessions multiplied by the session cap is the only bound on the bill.
    await runInDurableObject(voiceCap(), async (cap: GlobalCap) => {
      const t = Math.floor(Date.now() / 1000);
      for (let i = 0; i < limit(); i++) await cap.spend(t, limit());
    });

    const token = await register();
    // No interceptor: reaching AssemblyAI at all would fail the run under
    // disableNetConnect, which is the point — the refusal happens before it.
    const response = await send('/v1/voice/token', { token });

    expect(response.status).toBe(429);
    const body = (await response.json()) as { error: string; message: string };
    expect(body.error).toBe('service_busy');
    // Says what still works. A dead end here is a judge closing the tab.
    expect(body.message).toContain('Tapping the meal');
  });

  it('does not spend the day’s budget when the mint fails', async () => {
    interceptToken({ error: 'upstream is having a bad minute' }, 503);
    const token = await register();
    const before = await used();

    const response = await send('/v1/voice/token', { token });
    expect(response.status).toBe(503);

    // An AssemblyAI blip barely showed against a limit of two thousand. Against
    // thirty it is the whole afternoon, spent on conversations nobody had.
    expect(await used(), 'a failed mint still cost the deployment a session')
      .toBe(before);
  });

  it('hands the session back when the caller is the one out of allowance', async () => {
    const token = await register();
    await runInDurableObject(await quotaForDevice(token), async (q: QuotaCounter) => {
      const t = Math.floor(Date.now() / 1000);
      for (let i = 0; i < Number(env.VOICE_SESSIONS_PER_DAY); i++) await q.spend('voice', t);
    });
    const before = await used();

    const response = await send('/v1/voice/token', { token });
    expect(response.status).toBe(402);

    // Refusing one person must not quietly cost everybody else a conversation.
    expect(await used()).toBe(before);
  });
});
