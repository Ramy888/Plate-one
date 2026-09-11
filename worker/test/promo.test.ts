import {
  createExecutionContext,
  env,
  runInDurableObject,
  waitOnExecutionContext,
} from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';

import worker from '../src/index';
import { quotaForDevice } from './helpers';
import type { QuotaCounter } from '../src/quota';

const BASE = 'https://api.plateone.app';
const CODE = 'PLATE-TEST1';

let ipCounter = 0;

async function send(request: Request): Promise<Response> {
  const ctx = createExecutionContext();
  const response = await worker.fetch(request, env, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

async function register(): Promise<string> {
  const response = await send(
    new Request(`${BASE}/v1/device`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'cf-connecting-ip': `10.80.${Math.floor(++ipCounter / 250)}.${ipCounter % 250}`,
      },
      body: JSON.stringify({ platform: 'web' }),
    }),
  );
  return ((await response.json()) as { deviceToken: string }).deviceToken;
}

function redeem(token: string, code: string, ip?: string): Request {
  return new Request(`${BASE}/v1/promo`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
      'cf-connecting-ip': ip ?? `10.81.${Math.floor(++ipCounter / 250)}.${ipCounter % 250}`,
    },
    body: JSON.stringify({ code }),
  });
}

/** Uses up every conversation for this device. */
async function drain(token: string) {
  await runInDurableObject(await quotaForDevice(token), async (q: QuotaCounter) => {
    const t = Math.floor(Date.now() / 1000);
    const limit = Number(env.VOICE_SESSIONS_PER_DAY);
    for (let i = 0; i < limit; i++) await q.spend('voice', t);
  });
}

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare('DELETE FROM devices'),
    env.DB.prepare('DELETE FROM rate_limits'),
    env.DB.prepare('DELETE FROM promo_redemptions'),
  ]);
});

describe('redeeming a code', () => {
  it('gives back conversations to someone who has none', async () => {
    // The point of the whole feature: "come back tomorrow" is not an answer
    // when somebody is being shown the app across a table.
    const token = await register();
    await drain(token);

    const before = await send(
      new Request(`${BASE}/v1/quota`, {
        headers: { authorization: `Bearer ${token}`, 'cf-connecting-ip': '10.82.0.1' },
      }),
    );
    expect(((await before.json()) as { voice: number }).voice).toBe(0);

    const response = await send(redeem(token, CODE));
    expect(response.status).toBe(200);

    const body = (await response.json()) as {
      granted: number;
      quota: { plates: number; voice: number; bonus: boolean };
    };
    expect(body.granted).toBe(5);
    expect(body.quota.plates).toBe(Number(env.PLATES_PER_DAY) + 5);
    expect(body.quota.voice).toBe(5);
    expect(body.quota.bonus).toBe(true);
  });

  it('accepts it however it was typed', async () => {
    // Codes are read off a screen and typed by hand.
    const token = await register();
    const response = await send(redeem(token, '  plate-test1 '));
    expect(response.status).toBe(200);
  });

  it('gives pictures too, or the conversations run out of plates', async () => {
    const token = await register();
    const before = await runInDurableObject(
      await quotaForDevice(token),
      (q: QuotaCounter) => q.peek(Math.floor(Date.now() / 1000)),
    );

    await send(redeem(token, CODE));

    const after = await runInDurableObject(
      await quotaForDevice(token),
      (q: QuotaCounter) => q.peek(Math.floor(Date.now() / 1000)),
    );
    expect(after.previews).toBeGreaterThan(before.previews);
  });

  it('survives the daily reset', async () => {
    // Someone handed a code at nine in the evening should still have it in the
    // morning. Wiping it at midnight makes an evening code nearly worthless.
    const token = await register();
    await send(redeem(token, CODE));

    const stub = await quotaForDevice(token);
    const tomorrow = Math.floor(Date.now() / 1000) + 25 * 60 * 60;
    const view = await runInDurableObject(stub, (q: QuotaCounter) => q.peek(tomorrow));

    // The tries are the part that matters — they are what the code is for.
    expect(view.plates).toBe(Number(env.PLATES_PER_DAY) + 5);
    expect(view.voice).toBe(Number(env.VOICE_SESSIONS_PER_DAY) + 5);
    expect(view.bonus).toBe(true);
  });

  it('honours what each code is worth', async () => {
    const token = await register();
    const response = await send(redeem(token, 'PLATE-TEST2'));
    expect(((await response.json()) as { granted: number }).granted).toBe(3);
  });
});

describe('codes it refuses', () => {
  it('one nobody issued', async () => {
    const token = await register();
    const response = await send(redeem(token, 'PLATE-NOPE1'));
    expect(response.status).toBe(404);
  });

  it('the same code twice from the same person', async () => {
    const token = await register();
    expect((await send(redeem(token, CODE))).status).toBe(200);

    const again = await send(redeem(token, CODE));
    expect(again.status).toBe(409);
    expect(((await again.json()) as { error: string }).error).toBe('promo_used');
  });

  it('a code spent as many times as it is allowed', async () => {
    // A code is worth a fixed number of people. Here that is two.
    const uses = Number(env.PROMO_USES_PER_CODE);
    for (let i = 0; i < uses; i++) {
      expect((await send(redeem(await register(), CODE))).status).toBe(200);
    }

    const oneTooMany = await send(redeem(await register(), CODE));
    expect(oneTooMany.status).toBe(409);
    expect(((await oneTooMany.json()) as { error: string }).error).toBe('promo_spent');
  });

  it('lets a second person use a code the first one did', async () => {
    // The per-person check must not be a per-code check wearing a hat.
    expect((await send(redeem(await register(), CODE))).status).toBe(200);
    expect((await send(redeem(await register(), CODE))).status).toBe(200);
  });

  it('does not grant anything when it refuses', async () => {
    const token = await register();
    const before = await runInDurableObject(
      await quotaForDevice(token),
      (q: QuotaCounter) => q.peek(Math.floor(Date.now() / 1000)),
    );

    await send(redeem(token, 'PLATE-NOPE1'));

    const after = await runInDurableObject(
      await quotaForDevice(token),
      (q: QuotaCounter) => q.peek(Math.floor(Date.now() / 1000)),
    );
    expect(after.voice).toBe(before.voice);
  });

  it('anyone who has not registered a device', async () => {
    const response = await send(
      new Request(`${BASE}/v1/promo`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'cf-connecting-ip': '10.83.0.9' },
        body: JSON.stringify({ code: CODE }),
      }),
    );
    expect(response.status).toBe(401);
  });

  it('somebody working through the possibilities', async () => {
    // A code is short enough to guess at speed, and nothing else here would
    // stop that.
    const token = await register();
    const ip = '203.0.113.55';
    let limited = false;
    for (let i = 0; i < 25 && !limited; i++) {
      const response = await send(redeem(token, `PLATE-GUES${i}`, ip));
      if (response.status === 429) limited = true;
    }
    expect(limited, 'guesses were never rate limited').toBe(true);
  });

  it('says the same thing whether a code is wrong or the list is empty', async () => {
    // Otherwise "is promo configured here?" is a question anyone can ask.
    const token = await register();
    const response = await send(redeem(token, 'PLATE-NOPE2'));
    const body = (await response.json()) as { error: string; message: string };
    expect(body.error).toBe('promo_unknown');
    expect(body.message).not.toMatch(/configur|secret|empty/i);
  });
});
