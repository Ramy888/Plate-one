import {
  createExecutionContext,
  env,
  runInDurableObject,
  waitOnExecutionContext,
} from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';

import worker from '../src/index';
import { scratchCap } from './helpers';
import type { QuotaCounter } from '../src/quota';

const BASE = 'https://api.plateone.app';
const DAY = 24 * 60 * 60;

let ipCounter = 0;

async function call(
  method: string,
  path: string,
  options: { body?: unknown; token?: string; ip?: string } = {},
): Promise<Response> {
  const headers: Record<string, string> = {
    'cf-connecting-ip': options.ip ?? `10.0.${Math.floor(ipCounter / 250)}.${++ipCounter % 250}`,
  };
  if (options.body !== undefined) headers['content-type'] = 'application/json';
  if (options.token) headers.authorization = `Bearer ${options.token}`;

  const request = new Request(`${BASE}${path}`, {
    method,
    headers,
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
  });
  const ctx = createExecutionContext();
  const response = await worker.fetch(request, env, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

interface Quota {
  scans: number;
  previews: number;
  resetsAt: number;
}

async function register(platform = 'android') {
  const response = await call('POST', '/v1/device', { body: { platform } });
  expect(response.status).toBe(201);
  return (await response.json()) as { deviceToken: string; quota: Quota };
}

/** The Durable Object behind a device, for testing the counter directly. */
async function quotaStub(deviceToken: string) {
  const hash = await sha256Hex(deviceToken);
  const row = await env.DB.prepare('SELECT id FROM devices WHERE token_hash = ?')
    .bind(hash)
    .first<{ id: string }>();
  const id = env.QUOTA.idFromName(row!.id);
  return env.QUOTA.get(id);
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare('DELETE FROM reports'),
    env.DB.prepare('DELETE FROM scan_events'),
    env.DB.prepare('DELETE FROM devices'),
    env.DB.prepare('DELETE FROM rate_limits'),
  ]);
});

describe('health', () => {
  it('reports how much of the day’s budget is left', async () => {
    const response = await call('GET', '/health');
    const body = (await response.json()) as {
      ok: boolean;
      budget: { used: number; limit: number };
    };
    expect(body.ok).toBe(true);
    // A deployment that has spent its budget must say so out loud rather than
    // look healthy while refusing everything.
    expect(body.budget.limit).toBeGreaterThan(0);
    expect(body.budget.used).toBeGreaterThanOrEqual(0);
  });

  it('names the models it will call', async () => {
    const body = (await (await call('GET', '/health')).json()) as {
      models: { vision: string; image: string };
    };
    expect(body.models.vision).toBe('gemini-3.7-flash');
    expect(body.models.image).toBe('gemini-3.1-flash-image');
  });
});

describe('device registration', () => {
  it('issues a token and a free allowance', async () => {
    const { deviceToken, quota } = await register();
    expect(deviceToken).toBeTruthy();
    // Read from the binding, not repeated: the numbers are a deployment
    // decision and a test that hard-codes them fails for the wrong reason
    // every time one is tuned.
    expect(quota).toMatchObject({
      scans: Number(env.SCANS_PER_DAY),
      previews: Number(env.PREVIEWS_PER_DAY),
    });
  });

  it('stores only a hash of the token', async () => {
    const { deviceToken } = await register();
    const row = await env.DB.prepare('SELECT token_hash FROM devices').first<{
      token_hash: string;
    }>();
    expect(row?.token_hash).not.toBe(deviceToken);
    expect(row?.token_hash).toBe(await sha256Hex(deviceToken));
  });

  it('rejects an unknown platform', async () => {
    const response = await call('POST', '/v1/device', { body: { platform: 'windows' } });
    expect(response.status).toBe(400);
  });

  it('gives each registration its own token', async () => {
    const a = await register();
    const b = await register();
    expect(a.deviceToken).not.toBe(b.deviceToken);
  });

  it('caps registrations from one address', async () => {
    const ip = '198.51.100.20';
    let limited = false;
    for (let i = 0; i < 12; i++) {
      const response = await call('POST', '/v1/device', { ip, body: { platform: 'android' } });
      if (response.status === 429) {
        limited = true;
        break;
      }
    }
    expect(limited, 'registration was never rate limited').toBe(true);
  });
});

describe('quota endpoint', () => {
  it('needs a device token', async () => {
    expect((await call('GET', '/v1/quota')).status).toBe(401);
  });

  it('rejects a made-up token', async () => {
    expect((await call('GET', '/v1/quota', { token: 'nonsense' })).status).toBe(401);
  });

  it('reports the allowance without spending it', async () => {
    const { deviceToken } = await register();
    for (let i = 0; i < 3; i++) {
      const quota = (await (await call('GET', '/v1/quota', { token: deviceToken })).json()) as Quota;
      expect(quota.scans).toBe(8);
    }
  });
});

describe('quota bookkeeping', () => {
  it('refunds a unit when the model fails after it was taken', async () => {
    const { deviceToken } = await register();
    const stub = await quotaStub(deviceToken);
    await runInDurableObject(stub, async (instance: QuotaCounter) => {
      const t = Math.floor(Date.now() / 1000);
      await instance.spend('scan', t);
      expect((await instance.peek(t)).scans).toBe(7);
      await instance.refund('scan', t);
      expect((await instance.peek(t)).scans).toBe(8);
    });
  });

  it('a refund cannot mint allowance out of nothing', async () => {
    const { deviceToken } = await register();
    const stub = await quotaStub(deviceToken);
    await runInDurableObject(stub, async (instance: QuotaCounter) => {
      const t = Math.floor(Date.now() / 1000);
      await instance.refund('scan', t);
      await instance.refund('scan', t);
      expect((await instance.peek(t)).scans).toBe(8);
    });
  });

  it('keeps one device out of another', async () => {
    const a = await register();
    const b = await register();
    const stubA = await quotaStub(a.deviceToken);
    await runInDurableObject(stubA, async (instance: QuotaCounter) => {
      const t = Math.floor(Date.now() / 1000);
      for (let i = 0; i < 8; i++) await instance.spend('scan', t);
    });

    const quotaB = (await (await call('GET', '/v1/quota', { token: b.deviceToken })).json()) as Quota;
    expect(quotaB.scans).toBe(8);
  });
});

describe('reporting AI results', () => {
  it('accepts a report and stores it', async () => {
    const { deviceToken } = await register();
    const response = await call('POST', '/v1/report', {
      token: deviceToken,
      body: { targetType: 'preview', targetId: 'sc_1', reason: 'unrealistic', note: 'not my plate' },
    });
    expect(response.status).toBe(202);

    const row = await env.DB.prepare('SELECT reason, target_type FROM reports').first<{
      reason: string;
      target_type: string;
    }>();
    expect(row).toMatchObject({ reason: 'unrealistic', target_type: 'preview' });
  });

  it('normalises an unknown reason rather than rejecting it', async () => {
    const { deviceToken } = await register();
    await call('POST', '/v1/report', {
      token: deviceToken,
      body: { targetType: 'scan', targetId: 'sc_2', reason: 'something else entirely' },
    });
    const row = await env.DB.prepare('SELECT reason FROM reports').first<{ reason: string }>();
    expect(row?.reason).toBe('other');
  });

  it('never fails in front of the user, even on a malformed body', async () => {
    // Reporting offensive content must not be the thing that errors.
    const { deviceToken } = await register();
    const response = await call('POST', '/v1/report', { token: deviceToken, body: {} });
    expect(response.status).toBe(202);
  });

  it('still needs a registered device', async () => {
    expect((await call('POST', '/v1/report', { body: { targetId: 'x' } })).status).toBe(401);
  });
});

describe('deleting a device', () => {
  it('removes the row, its events and its reports', async () => {
    const { deviceToken } = await register();
    await call('POST', '/v1/report', {
      token: deviceToken,
      body: { targetType: 'scan', targetId: 'sc_3', reason: 'other' },
    });

    expect((await call('DELETE', '/v1/device', { token: deviceToken })).status).toBe(204);

    for (const table of ['devices', 'reports', 'scan_events']) {
      const row = await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{ n: number }>();
      expect(row?.n, `${table} still has rows`).toBe(0);
    }
  });

  it('invalidates the token it was called with', async () => {
    const { deviceToken } = await register();
    await call('DELETE', '/v1/device', { token: deviceToken });
    expect((await call('GET', '/v1/quota', { token: deviceToken })).status).toBe(401);
  });

  it('clears the quota, so a re-register does not inherit a spent one', async () => {
    const { deviceToken } = await register();
    const stub = await quotaStub(deviceToken);
    await runInDurableObject(stub, async (instance: QuotaCounter) => {
      const t = Math.floor(Date.now() / 1000);
      for (let i = 0; i < 8; i++) await instance.spend('scan', t);
    });

    await call('DELETE', '/v1/device', { token: deviceToken });

    await runInDurableObject(stub, async (instance: QuotaCounter) => {
      expect((await instance.peek(Math.floor(Date.now() / 1000))).scans).toBe(8);
    });
  });
});

describe('the deployment-wide cap', () => {
  it('refuses everyone once the day’s budget is gone', async () => {
    // This is the thing standing between a public demo URL and an empty API
    // account, so it is worth draining rather than trusting.
    const cap = scratchCap('exhaustion');
    const drained = await runInDurableObject(cap, async (instance) => {
      const t = Math.floor(Date.now() / 1000);
      let last = await instance.spend(t);
      while (last.ok) last = await instance.spend(t);
      return last;
    });
    expect(drained.ok).toBe(false);
    expect(drained.used).toBe(drained.limit);

    const again = await runInDurableObject(cap, (instance) =>
      instance.spend(Math.floor(Date.now() / 1000)));
    expect(again.ok).toBe(false);
  });

  it('starts a fresh budget the next day', async () => {
    const t = Math.floor(Date.now() / 1000);
    const cap = scratchCap('rollover');
    await runInDurableObject(cap, async (instance) => {
      let last = await instance.spend(t);
      while (last.ok) last = await instance.spend(t);
    });

    const tomorrow = await runInDurableObject(cap, (instance) =>
      instance.spend(t + DAY + 1));
    expect(tomorrow.ok).toBe(true);
    expect(tomorrow.used).toBe(1);
  });

  it('is not touched by a call that costs nothing', async () => {
    const { deviceToken } = await register();
    const before = (await (await call('GET', '/health')).json()) as {
      budget: { used: number };
    };

    await call('GET', '/v1/quota', { token: deviceToken });

    const after = (await (await call('GET', '/health')).json()) as {
      budget: { used: number };
    };
    expect(after.budget.used).toBe(before.budget.used);
  });
});

describe('routing', () => {
  it('404s an unknown path', async () => {
    expect((await call('GET', '/v1/nope')).status).toBe(404);
  });

  it('405s a wrong method and says what is allowed', async () => {
    const response = await call('PUT', '/v1/quota');
    expect(response.status).toBe(405);
    expect(response.headers.get('allow')).toContain('GET');
  });

  it('never caches', async () => {
    expect((await call('GET', '/health')).headers.get('cache-control')).toBe('no-store');
  });

  it('does not leak internals in an error body', async () => {
    const text = await (await call('POST', '/v1/device', { body: {} })).text();
    expect(text).not.toMatch(/sqlite|D1_|stack|at Object/i);
  });
});
