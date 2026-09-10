import { createExecutionContext, env, waitOnExecutionContext } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';

import worker from '../src/index';

const BASE = 'https://api.plateone.app';

/** The app's own page, and one that is not. */
const OURS = 'http://localhost:8080';
const THEIRS = 'https://not-plate-one.example';

let ipCounter = 0;

function send(
  path: string,
  { method = 'GET', origin, headers = {} }: {
    method?: string;
    origin?: string;
    headers?: Record<string, string>;
  } = {},
): Promise<Response> {
  const all: Record<string, string> = {
    'cf-connecting-ip': `10.60.${Math.floor(++ipCounter / 250)}.${ipCounter % 250}`,
    ...headers,
  };
  if (origin) all.origin = origin;

  const ctx = createExecutionContext();
  return worker
    .fetch(new Request(`${BASE}${path}`, { method, headers: all }), env, ctx)
    .then(async (response) => {
      await waitOnExecutionContext(ctx);
      return response;
    });
}

describe('cross-origin access', () => {
  it('lets the app page call the API', async () => {
    // Without this the browser refuses every call before it is sent, the app
    // looks offline, and the Worker's log stays empty.
    const response = await send('/health', { origin: OURS });

    expect(response.status).toBe(200);
    expect(response.headers.get('access-control-allow-origin')).toBe(OURS);
    expect(response.headers.get('vary')).toContain('Origin');
  });

  it('answers the preflight a POST with a token triggers', async () => {
    // `Authorization` is not a simple header, so every /v1 call from a browser
    // is preceded by one of these. Answering it wrong fails the real request
    // with no useful error anywhere.
    const response = await send('/v1/voice/token', {
      method: 'OPTIONS',
      origin: OURS,
      headers: {
        'access-control-request-method': 'POST',
        'access-control-request-headers': 'authorization',
      },
    });

    expect(response.status).toBe(204);
    expect(response.headers.get('access-control-allow-origin')).toBe(OURS);
    expect(response.headers.get('access-control-allow-headers')).toContain('authorization');
    expect(response.headers.get('access-control-allow-methods')).toContain('POST');
  });

  it('refuses a site that is not ours', async () => {
    // Not because CORS protects the device token — it does not — but because
    // any page allowed here can spend this deployment's budget through its own
    // visitors' browsers.
    const response = await send('/health', { origin: THEIRS });
    expect(response.headers.get('access-control-allow-origin')).toBeNull();

    const options = await send('/v1/voice/token', {
      method: 'OPTIONS',
      origin: THEIRS,
      headers: { 'access-control-request-method': 'POST' },
    });
    expect(options.status).toBe(403);
    expect(options.headers.get('access-control-allow-origin')).toBeNull();
  });

  it('varies on Origin even when it refuses', async () => {
    // Otherwise a cache can hand our page the answer computed for someone
    // else's, which fails in a way nobody will reproduce.
    const response = await send('/health', { origin: THEIRS });
    expect(response.headers.get('vary')).toContain('Origin');
  });

  it('adds nothing to a request that is not from a browser', async () => {
    const response = await send('/health');
    expect(response.headers.get('access-control-allow-origin')).toBeNull();
    expect(response.headers.get('vary')).toBeNull();
  });

  it('puts the headers on failures too', async () => {
    // A 402 the browser blocks is a 402 nobody can read. Errors need these
    // more than successes do — they are what the app has to explain.
    const response = await send('/v1/quota', { origin: OURS });
    expect(response.status).toBe(401);
    expect(response.headers.get('access-control-allow-origin')).toBe(OURS);
  });

  it('puts them on a 404 and a 405 as well', async () => {
    // Both are produced before any handler runs, which is exactly where a
    // per-route implementation would have missed them.
    const missing = await send('/v1/nothing', { origin: OURS });
    expect(missing.status).toBe(404);
    expect(missing.headers.get('access-control-allow-origin')).toBe(OURS);

    const wrongMethod = await send('/v1/voice/token', { origin: OURS });
    expect(wrongMethod.status).toBe(405);
    expect(wrongMethod.headers.get('access-control-allow-origin')).toBe(OURS);
  });

  it('leaves a bare OPTIONS to the router', async () => {
    // A preflight always names the method it is asking about. Without that
    // header this is just a request for an endpoint that takes POST.
    const response = await send('/v1/voice/token', { method: 'OPTIONS', origin: OURS });
    expect(response.status).toBe(405);
  });
});
