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

async function register(): Promise<string> {
  const response = await send(
    new Request(`${BASE}/v1/device`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'cf-connecting-ip': `10.30.${Math.floor(++ipCounter / 250)}.${ipCounter % 250}`,
      },
      body: JSON.stringify({ platform: 'web' }),
    }),
  );
  return ((await response.json()) as { deviceToken: string }).deviceToken;
}

function plateRequest(
  token: string,
  body: Record<string, unknown>,
): Request {
  return new Request(`${BASE}/v1/plate`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
      'cf-connecting-ip': `10.31.${Math.floor(++ipCounter / 250)}.${ipCounter % 250}`,
    },
    body: JSON.stringify(body),
  });
}

/** The caption model. The picture is a separate binding. */
function interceptCaption(reply: string, times = 1) {
  fetchMock
    .get(GEMINI)
    .intercept({ path: (p) => p.includes(':generateContent'), method: 'POST' })
    .reply(200, {
      candidates: [
        {
          content: {
            parts: [{ text: JSON.stringify({ reply, foodIds: [], additionId: '' }) }],
          },
        },
      ],
    })
    .times(times);
}

/** One tiny JPEG, base64, as Flux would return it. */
const FAKE_IMAGE_B64 = btoa(String.fromCharCode(0xff, 0xd8, 0xff, 0xd9));

/**
 * Workers AI has no local simulator and the binding is marked remote, so a
 * test that wants a picture has to supply one. Returns a record of every
 * prompt it was asked to draw, which is how the cache is proved: a second
 * request for the same plate must not reach this at all.
 */
function stubImages(): { prompts: string[]; restore: () => void } {
  const prompts: string[] = [];
  const original = env.AI;
  (env as { AI: unknown }).AI = {
    run: async (_model: string, input: { prompt: string }) => {
      prompts.push(input.prompt);
      return { image: FAKE_IMAGE_B64 };
    },
  };
  return { prompts, restore: () => ((env as { AI: unknown }).AI = original) };
}

beforeAll(() => {
  fetchMock.activate();
  fetchMock.disableNetConnect();
});

afterEach(() => fetchMock.assertNoPendingInterceptors());

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare('DELETE FROM scan_events'),
    env.DB.prepare('DELETE FROM devices'),
    env.DB.prepare('DELETE FROM rate_limits'),
  ]);
  const listed = await env.PREVIEWS.list({ prefix: 'p/' });
  await Promise.all(listed.objects.map((o) => env.PREVIEWS.delete(o.key)));
});

describe('drawing the meal as it is described', () => {
  it('draws a plate with no addition on it, and writes no caption', async () => {
    // The voice screen draws the meal while the conversation is still filling
    // it in, long before anything has been suggested. Nothing displays a
    // caption at that point, so asking a model for one is a round trip spent
    // on something nobody reads — and no interceptor is registered here, so a
    // caption call would fail against disableNetConnect rather than pass
    // quietly.
    const images = stubImages();

    const response = await send(
      plateRequest(await register(), { foodIds: ['white_rice', 'chicken'] }),
    );

    expect(response.status).toBe(200);
    {
      const body = (await response.json()) as {
        imageUrl: string;
        additionId: string;
        reply: string;
      };
      expect(body.additionId).toBe('');
      expect(body.reply).toBe('');
      expect(body.imageUrl).toContain('/v1/preview/');
    }
    // Nothing is being added, so the prompt must not claim anything is.
    expect(images.prompts).toHaveLength(1);
    expect(images.prompts[0]).not.toContain('added to the side');
    images.restore();
  });

  it('still refuses an addition that is not in the catalogue', async () => {
    // An empty addition means "no addition". It does not mean the id stopped
    // being checked — that check is what keeps free text out of the image model.
    const response = await send(
      plateRequest(await register(), {
        foodIds: ['white_rice'],
        additionId: 'a photorealistic portrait of a person',
      }),
    );
    expect(response.status).toBe(400);
  });
});

describe('the same plate is only drawn once', () => {
  it('serves a repeat from storage without touching a model', async () => {
    // Under the voice screen someone flips between three suggestions on one
    // meal. Without this, flipping back costs another image and another
    // fifteen seconds of waiting.
    const images = stubImages();
    interceptCaption('Rice with hummus.');
    const token = await register();

    const first = await send(
      plateRequest(token, { foodIds: ['white_rice'], additionId: 'hummus' }),
    );
    const firstBody = (await first.json()) as { imageUrl: string; cached: boolean };
    expect(firstBody.cached).toBe(false);

    const spent = await runInDurableObject(
      await quotaForDevice(token),
      (q: QuotaCounter) => q.peek(Math.floor(Date.now() / 1000)),
    );

    // No second caption interceptor and no second image: if either model is
    // reached, this fails.
    const second = await send(
      plateRequest(token, { foodIds: ['white_rice'], additionId: 'hummus' }),
    );
    const secondBody = (await second.json()) as {
      imageUrl: string;
      reply: string;
      cached: boolean;
    };

    expect(secondBody.cached).toBe(true);
    expect(secondBody.imageUrl).toBe(firstBody.imageUrl);
    expect(secondBody.reply).toBe('Rice with hummus.');
    expect(images.prompts).toHaveLength(1);

    // And it is free. A picture already drawn costs nothing to hand over
    // again, and charging for it would spend a conversation's allowance twice
    // on the same plate.
    const after = await runInDurableObject(
      await quotaForDevice(token),
      (q: QuotaCounter) => q.peek(Math.floor(Date.now() / 1000)),
    );
    expect(after.previews).toBe(spent.previews);
    images.restore();
  });

  it('treats the same foods in a different order as the same plate', async () => {
    // "rice and chicken" and "chicken and rice" are one meal. Someone naming
    // them in a different order must not pay for a second picture of it.
    const images = stubImages();
    const token = await register();

    await send(plateRequest(token, { foodIds: ['white_rice', 'chicken'] }));
    const second = await send(
      plateRequest(token, { foodIds: ['chicken', 'white_rice'] }),
    );

    expect(((await second.json()) as { cached: boolean }).cached).toBe(true);
    expect(images.prompts).toHaveLength(1);
    images.restore();
  });

  it('draws a different picture when the addition changes', async () => {
    // The cache must not be so eager that trying a second suggestion shows the
    // first one's picture.
    const images = stubImages();
    interceptCaption('One.', 2);
    const token = await register();

    const a = await send(
      plateRequest(token, { foodIds: ['white_rice'], additionId: 'hummus' }),
    );
    const b = await send(
      plateRequest(token, { foodIds: ['white_rice'], additionId: 'side_salad' }),
    );

    const urlA = ((await a.json()) as { imageUrl: string }).imageUrl;
    const urlB = ((await b.json()) as { imageUrl: string }).imageUrl;
    expect(urlA).not.toBe(urlB);
    expect(images.prompts).toHaveLength(2);
    images.restore();
  });

  it('serves a cached plate back through the picture route', async () => {
    // The key is no longer a UUID, and the route that reads it validates the
    // shape. A cache nobody can read back is not a cache.
    const images = stubImages();
    const token = await register();

    const drawn = await send(plateRequest(token, { foodIds: ['white_rice'] }));
    const { imageUrl } = (await drawn.json()) as { imageUrl: string };

    const picture = await send(
      new Request(imageUrl, { headers: { authorization: `Bearer ${token}` } }),
    );
    expect(picture.status).toBe(200);
    expect(picture.headers.get('content-type')).toContain('image/jpeg');
    images.restore();
  });
});

describe('what a picture costs', () => {
  it('refuses once the device allowance is gone, without calling a model', async () => {
    const token = await register();
    await runInDurableObject(await quotaForDevice(token), async (q: QuotaCounter) => {
      const t = Math.floor(Date.now() / 1000);
      const limit = Number(env.PREVIEWS_PER_DAY);
      for (let i = 0; i < limit; i++) await q.spend('preview', t);
    });

    // No interceptor and no image stub: if this reaches either model, it fails
    // against disableNetConnect rather than passing quietly.
    const response = await send(plateRequest(token, { foodIds: ['white_rice'] }));
    expect(response.status).toBe(402);
    expect(((await response.json()) as { error: string }).error).toBe('quota_exhausted');
  });

  it('refuses a paid call once the deployment’s budget is gone', async () => {
    // The per-device allowance stops one phone running up a bill. This is the
    // one that stops a hundred phones, or a script rotating device ids, and it
    // is the only thing standing between a public demo URL and an empty API
    // account — so it is tested through a route, not just the counter.
    const token = await register();
    const t = Math.floor(Date.now() / 1000);
    try {
      await runInDurableObject(globalCap(), async (instance) => {
        let last = await instance.spend(t);
        while (last.ok) last = await instance.spend(t);
      });

      const response = await send(plateRequest(token, { foodIds: ['white_rice'] }));
      expect(response.status).toBe(429);
      expect(((await response.json()) as { error: string }).error).toBe('service_busy');
    } finally {
      // Shared across every suite in the run — storage isolation is off — so
      // this belongs in `finally`, not at the end of the happy path.
      await runInDurableObject(globalCap(), async (_instance, state) => {
        await state.storage.deleteAll();
      });
    }
  });

  it('caps paid calls per IP as well as per device', async () => {
    const ip = '203.0.113.77';
    let limited = false;
    for (let i = 0; i < 60 && !limited; i++) {
      const token = await register();
      // Empty the device allowance so the IP ceiling is what is being measured.
      await runInDurableObject(await quotaForDevice(token), async (q: QuotaCounter) => {
        const t = Math.floor(Date.now() / 1000);
        const limit = Number(env.PREVIEWS_PER_DAY);
        for (let j = 0; j < limit; j++) await q.spend('preview', t);
      });

      const request = new Request(`${BASE}/v1/plate`, {
        method: 'POST',
        headers: {
          authorization: `Bearer ${token}`,
          'content-type': 'application/json',
          'cf-connecting-ip': ip,
        },
        body: JSON.stringify({ foodIds: ['white_rice'] }),
      });
      if ((await send(request)).status === 429) limited = true;
    }
    expect(limited, 'plates were never rate limited per IP').toBe(true);
  });
});
