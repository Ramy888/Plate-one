import {
  createExecutionContext,
  env,
  waitOnExecutionContext,
} from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';

import worker from '../src/index';
import { PREVIEW_DISCLAIMER, PREVIEW_DISCLAIMER_ASCII } from '../src/preview';

const BASE = 'https://api.plateone.app';

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
        'cf-connecting-ip': `10.40.${Math.floor(++ipCounter / 250)}.${ipCounter % 250}`,
      },
      body: JSON.stringify({ platform: 'web' }),
    }),
  );
  return ((await response.json()) as { deviceToken: string }).deviceToken;
}

function read(url: string, token?: string): Request {
  return new Request(url, {
    headers: {
      ...(token == null ? {} : { authorization: `Bearer ${token}` }),
      'cf-connecting-ip': `10.41.${Math.floor(++ipCounter / 250)}.${ipCounter % 250}`,
    },
  });
}

/** A plate key, of the shape `plate.ts` writes. */
const KEY = `plate-${'ab12'.repeat(8)}.jpg`;

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare('DELETE FROM devices'),
    env.DB.prepare('DELETE FROM rate_limits'),
  ]);
  const listed = await env.PREVIEWS.list({ prefix: 'p/' });
  await Promise.all(listed.objects.map((o) => env.PREVIEWS.delete(o.key)));
});

describe('the disclaimer', () => {
  it('is ASCII in a header, while the body keeps the real punctuation', () => {
    // A header cannot carry an em dash, and a silently mangled one is worse
    // than a plain hyphen.
    expect(PREVIEW_DISCLAIMER).toContain('—');
    expect(PREVIEW_DISCLAIMER_ASCII).not.toContain('—');
    // eslint-disable-next-line no-control-regex
    expect(/^[\x20-\x7e]*$/.test(PREVIEW_DISCLAIMER_ASCII)).toBe(true);
  });
});

describe('serving a picture', () => {
  it('serves it, marked as AI generated', async () => {
    const token = await register();
    await env.PREVIEWS.put(`p/${KEY}`, new Uint8Array([0xff, 0xd8, 0xff, 0xd9]), {
      httpMetadata: { contentType: 'image/jpeg' },
    });

    const response = await send(read(`${BASE}/v1/preview/${KEY}`, token));
    expect(response.status).toBe(200);
    expect(response.headers.get('x-ai-generated')).toBe('true');
    expect(response.headers.get('x-disclaimer')).toBe(PREVIEW_DISCLAIMER_ASCII);
    expect(response.headers.get('content-type')).toContain('image');
  });

  it('needs a device token, so the bucket is not a public host', async () => {
    await env.PREVIEWS.put(`p/${KEY}`, new Uint8Array([0xff, 0xd8]));
    expect((await send(read(`${BASE}/v1/preview/${KEY}`))).status).toBe(401);
  });

  it('rejects a name that is not one of ours', async () => {
    const token = await register();
    for (const name of ['..%2Fsecrets', 'plate-nothex.jpg', `${crypto.randomUUID()}.jpg`]) {
      const response = await send(read(`${BASE}/v1/preview/${name}`, token));
      expect(response.status, name).toBe(400);
    }
  });

  it('says plainly when a picture has expired', async () => {
    const token = await register();
    const response = await send(read(`${BASE}/v1/preview/${KEY}`, token));

    expect(response.status).toBe(404);
    const body = (await response.json()) as { error: string; message: string };
    expect(body.error).toBe('preview_expired');
    expect(body.message).toContain('24 hours');
  });
});
