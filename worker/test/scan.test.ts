import {
  createExecutionContext,
  env,
  fetchMock,
  runInDurableObject,
  waitOnExecutionContext,
} from 'cloudflare:test';
import { afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import worker from '../src/index';
import { globalCap, quotaForDevice } from './helpers';
import type { QuotaCounter } from '../src/quota';

const BASE = 'https://api.plateone.app';
const GEMINI = 'https://generativelanguage.googleapis.com';

let ipCounter = 0;

async function send(request: Request): Promise<Response> {
  const ctx = createExecutionContext();
  const response = await worker.fetch(request, env, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

function scanRequest(token: string, body: FormData, ip?: string): Request {
  return new Request(`${BASE}/v1/scan`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${token}`,
      'cf-connecting-ip': ip ?? `10.5.0.${++ipCounter % 250}`,
    },
    body,
  });
}

function photo(bytes = 2048, type = 'image/jpeg'): FormData {
  const form = new FormData();
  form.append('image', new File([new Uint8Array(bytes)], 'meal.jpg', { type }));
  return form;
}

async function register(): Promise<string> {
  const response = await send(
    new Request(`${BASE}/v1/device`, {
      method: 'POST',
      // A fresh address each time, or registration hits its own IP limit and
      // later tests get no token at all.
      headers: {
        'content-type': 'application/json',
        'cf-connecting-ip': `10.6.${Math.floor(++ipCounter / 250)}.${ipCounter % 250}`,
      },
      body: JSON.stringify({ platform: 'android' }),
    }),
  );
  return ((await response.json()) as { deviceToken: string }).deviceToken;
}

async function quotaStub(token: string) {
  return quotaForDevice(token);
}

/** A well-formed model response. */
function geminiReply(foods: { name: string; confidence: number }[], components?: object) {
  return {
    candidates: [
      {
        content: {
          parts: [
            {
              text: JSON.stringify({
                foods,
                components: components ?? {
                  protein: 'present',
                  fibre: 'possibly_missing',
                  healthy_fat: 'uncertain',
                },
              }),
            },
          ],
        },
      },
    ],
  };
}

function interceptGemini(reply: object, status = 200, times = 1) {
  fetchMock
    .get(GEMINI)
    .intercept({ path: (p) => p.includes(':generateContent'), method: 'POST' })
    .reply(status, reply)
    .times(times);
}

beforeAll(() => {
  fetchMock.activate();
  // Anything not explicitly intercepted should fail loudly rather than
  // silently reach the real, paid API from a test run.
  fetchMock.disableNetConnect();
});

afterEach(() => fetchMock.assertNoPendingInterceptors());

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare('DELETE FROM reports'),
    env.DB.prepare('DELETE FROM scan_events'),
    env.DB.prepare('DELETE FROM devices'),
    env.DB.prepare('DELETE FROM rate_limits'),
  ]);
});

describe('recognition', () => {
  it('returns the foods the model saw', async () => {
    const token = await register();
    interceptGemini(
      geminiReply([
        { name: 'white rice', confidence: 0.98 },
        { name: 'roast chicken thigh', confidence: 0.95 },
      ]),
    );

    const response = await send(scanRequest(token, photo()));
    expect(response.status).toBe(200);

    const body = (await response.json()) as {
      scanId: string;
      foods: { name: string; confidence: number }[];
      components: { protein: string; fibre: string; healthyFat: string };
      quota: { scans: number };
    };
    expect(body.scanId).toBeTruthy();
    expect(body.foods.map((f) => f.name)).toEqual(['white rice', 'roast chicken thigh']);
    expect(body.components).toEqual({
      protein: 'present',
      fibre: 'possibly_missing',
      healthyFat: 'uncertain',
    });
    expect(body.quota.scans).toBe(7);
  });

  it('spends exactly one scan', async () => {
    const token = await register();
    interceptGemini(geminiReply([{ name: 'rice', confidence: 0.9 }]));
    await send(scanRequest(token, photo()));

    const stub = await quotaStub(token);
    await runInDurableObject(stub, async (instance: QuotaCounter) => {
      expect((await instance.peek(Math.floor(Date.now() / 1000))).scans).toBe(7);
    });
  });

  it('clamps a confidence the model got wrong', async () => {
    const token = await register();
    interceptGemini(geminiReply([{ name: 'rice', confidence: 7.5 }]));
    const body = (await (await send(scanRequest(token, photo()))).json()) as {
      foods: { confidence: number }[];
    };
    expect(body.foods[0].confidence).toBe(1);
  });

  it('drops a nameless entry rather than passing it on', async () => {
    const token = await register();
    interceptGemini(
      geminiReply([
        { name: '   ', confidence: 0.9 },
        { name: 'rice', confidence: 0.9 },
      ]),
    );
    const body = (await (await send(scanRequest(token, photo()))).json()) as {
      foods: { name: string }[];
    };
    expect(body.foods).toHaveLength(1);
  });

  it('records the attempt without recording the meal', async () => {
    const token = await register();
    interceptGemini(geminiReply([{ name: 'grilled halloumi', confidence: 0.9 }]));
    await send(scanRequest(token, photo()));

    const row = await env.DB.prepare('SELECT * FROM scan_events').first<Record<string, unknown>>();
    expect(row?.outcome).toBe('ok');
    expect(row?.matched_count).toBe(1);
    // Nothing in the row should name the food.
    expect(JSON.stringify(row)).not.toContain('halloumi');
  });
});

describe('when the model finds nothing', () => {
  it('says so, and gives the scan back', async () => {
    const token = await register();
    interceptGemini(geminiReply([]));

    const response = await send(scanRequest(token, photo()));
    expect(response.status).toBe(422);
    expect((await response.json() as { error: string }).error).toBe('no_food_found');

    // Charging someone a scan for a photo the model could not read would be
    // indefensible, so the unit comes back.
    const stub = await quotaStub(token);
    await runInDurableObject(stub, async (instance: QuotaCounter) => {
      expect((await instance.peek(Math.floor(Date.now() / 1000))).scans).toBe(8);
    });
  });

  it('records it as empty rather than as an error', async () => {
    const token = await register();
    interceptGemini(geminiReply([]));
    await send(scanRequest(token, photo()));
    const row = await env.DB.prepare('SELECT outcome FROM scan_events').first<{ outcome: string }>();
    expect(row?.outcome).toBe('empty');
  });
});

describe('when the model fails', () => {
  it('refunds the scan and offers the manual builder', async () => {
    const token = await register();
    // 503 is retried, so every attempt has to be intercepted.
    interceptGemini({ error: 'overloaded' }, 503, 3);

    const response = await send(scanRequest(token, photo()));
    expect(response.status).toBe(503);
    const body = (await response.json()) as { error: string; message: string };
    expect(body.error).toBe('recognition_busy');
    expect(body.message).toContain('by hand');

    const stub = await quotaStub(token);
    await runInDurableObject(stub, async (instance: QuotaCounter) => {
      expect((await instance.peek(Math.floor(Date.now() / 1000))).scans).toBe(8);
    });
  });

  it('retries a 503 before giving up', async () => {
    const token = await register();
    interceptGemini({ error: 'overloaded' }, 503, 2);
    interceptGemini(geminiReply([{ name: 'rice', confidence: 0.9 }]));

    const response = await send(scanRequest(token, photo()));
    expect(response.status).toBe(200);
  });

  it('does not retry a client error', async () => {
    const token = await register();
    // One interceptor only: a second attempt would fail the pending check.
    interceptGemini({ error: 'bad request' }, 400, 1);

    const response = await send(scanRequest(token, photo()));
    expect(response.status).toBe(502);
    expect((await response.json() as { error: string }).error).toBe('recognition_failed');
  });

  it('treats a blocked prompt as "not a meal", and refunds', async () => {
    const token = await register();
    interceptGemini({ promptFeedback: { blockReason: 'SAFETY' } }, 200, 1);

    const response = await send(scanRequest(token, photo()));
    expect(response.status).toBe(422);
    expect((await response.json() as { error: string }).error).toBe('not_a_meal');

    const stub = await quotaStub(token);
    await runInDurableObject(stub, async (instance: QuotaCounter) => {
      expect((await instance.peek(Math.floor(Date.now() / 1000))).scans).toBe(8);
    });
  });

  it('survives a response that is not the JSON it promised', async () => {
    const token = await register();
    // A 200 carrying unparseable text is not retried — the HTTP call
    // succeeded, so only one interceptor is consumed.
    interceptGemini(
      { candidates: [{ content: { parts: [{ text: 'sorry, I cannot do that' }] } }] },
      200,
      1,
    );
    const response = await send(scanRequest(token, photo()));
    expect(response.status).toBe(503);
  });
});

describe('the upload itself', () => {
  it('needs a registered device', async () => {
    const request = new Request(`${BASE}/v1/scan`, {
      method: 'POST',
      headers: { 'cf-connecting-ip': '10.7.0.1' },
      body: photo(),
    });
    expect((await send(request)).status).toBe(401);
  });

  it('needs a photo', async () => {
    const token = await register();
    const form = new FormData();
    form.append('notimage', 'x');
    const response = await send(scanRequest(token, form));
    expect(response.status).toBe(400);
    expect((await response.json() as { error: string }).error).toBe('missing_image');
  });

  it('rejects an empty file', async () => {
    const token = await register();
    const form = new FormData();
    form.append('image', new File([], 'meal.jpg', { type: 'image/jpeg' }));
    expect((await send(scanRequest(token, form))).status).toBe(400);
  });

  it('rejects one over the size ceiling', async () => {
    const token = await register();
    const response = await send(scanRequest(token, photo(500 * 1024)));
    expect(response.status).toBe(413);
  });

  it('rejects a type that is not an image', async () => {
    const token = await register();
    const form = new FormData();
    form.append('image', new File([new Uint8Array(64)], 'meal.pdf', { type: 'application/pdf' }));
    expect((await send(scanRequest(token, form))).status).toBe(415);
  });

  it('never reaches the model when the upload is rejected', async () => {
    // No interceptor registered: if a call escaped, disableNetConnect fails it.
    const token = await register();
    await send(scanRequest(token, photo(500 * 1024)));
  });
});

describe('quota enforcement', () => {
  it('refuses once the allowance is gone, without calling the model', async () => {
    const token = await register();
    const stub = await quotaStub(token);
    await runInDurableObject(stub, async (instance: QuotaCounter) => {
      const t = Math.floor(Date.now() / 1000);
      for (let i = 0; i < 8; i++) await instance.spend('scan', t);
    });

    const response = await send(scanRequest(token, photo()));
    expect(response.status).toBe(402);
    expect((await response.json() as { error: string }).error).toBe('quota_exhausted');
  });

  it('refuses a paid call once the deployment’s budget is gone', async () => {
    // The per-device allowance stops one phone running up a bill. This is the
    // one that stops a hundred phones, or a script rotating device ids, and it
    // is the only thing standing between a public demo URL and an empty API
    // account — so it is tested through the route, not just the counter.
    const token = await register();
    const t = Math.floor(Date.now() / 1000);
    try {
      await runInDurableObject(globalCap(), async (instance) => {
        let last = await instance.spend(t);
        while (last.ok) last = await instance.spend(t);
      });

      // No interceptor registered: if this reaches the model at all, the test
      // fails against disableNetConnect rather than passing quietly.
      const response = await send(scanRequest(token, photo()));
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

  it('caps paid calls per IP as well as per device', async () => {
    const ip = '203.0.113.99';
    let limited = false;
    for (let i = 0; i < 25 && !limited; i++) {
      const token = await register();
      const stub = await quotaStub(token);
      // Empty the device quota so the IP limit is what is being measured.
      await runInDurableObject(stub, async (instance: QuotaCounter) => {
        const t = Math.floor(Date.now() / 1000);
        for (let j = 0; j < 8; j++) await instance.spend('scan', t);
      });
      const response = await send(scanRequest(token, photo(), ip));
      if (response.status === 429) limited = true;
    }
    expect(limited, 'scans were never rate limited per IP').toBe(true);
  });
});
