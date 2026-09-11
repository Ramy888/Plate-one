import {
  createExecutionContext,
  env,
  fetchMock,
  runInDurableObject,
  waitOnExecutionContext,
} from 'cloudflare:test';
import { afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import worker from '../src/index';
import { sha256Hex } from './helpers';
import type { QuotaCounter } from '../src/quota';

const BASE = 'https://api.plateone.app';
const GOOGLE = 'https://www.googleapis.com';

const CLIENT_ID = env.GOOGLE_CLIENT_ID;

let ipCounter = 0;

async function send(request: Request): Promise<Response> {
  const ctx = createExecutionContext();
  const response = await worker.fetch(request, env, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

function registerRequest(body: Record<string, unknown>): Request {
  return new Request(`${BASE}/v1/device`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'cf-connecting-ip': `10.70.${Math.floor(++ipCounter / 250)}.${ipCounter % 250}`,
    },
    body: JSON.stringify(body),
  });
}

// ---------------------------------------------------------------- the signer
//
// A real RSA key pair, generated once for the suite. Tokens are signed with it
// and the public half is served where Google's would be — so these tests check
// the actual signature path rather than a stub of it.

let signing: CryptoKeyPair;
let jwk: JsonWebKey;
const KID = 'test-key-1';

function b64url(bytes: Uint8Array | string): string {
  const binary =
    typeof bytes === 'string' ? bytes : String.fromCharCode(...bytes);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function signToken(
  claims: Record<string, unknown>,
  { kid = KID, alg = 'RS256' } = {},
): Promise<string> {
  const header = b64url(JSON.stringify({ alg, kid, typ: 'JWT' }));
  const payload = b64url(JSON.stringify(claims));
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      'RSASSA-PKCS1-v1_5',
      signing.privateKey,
      new TextEncoder().encode(`${header}.${payload}`),
    ),
  );
  return `${header}.${payload}.${b64url(signature)}`;
}

function goodClaims(overrides: Record<string, unknown> = {}) {
  const now = Math.floor(Date.now() / 1000);
  return {
    iss: 'https://accounts.google.com',
    aud: CLIENT_ID,
    sub: '1078349201',
    exp: now + 3600,
    iat: now,
    email: 'someone@example.com',
    name: 'Someone',
    ...overrides,
  };
}

/** Serves our public key where Google's live. Consumed once per lookup. */
function interceptCerts(times = 1) {
  fetchMock
    .get(GOOGLE)
    .intercept({ path: (p) => p.startsWith('/oauth2/v3/certs'), method: 'GET' })
    .reply(200, { keys: [{ ...jwk, kid: KID, alg: 'RS256', use: 'sig' }] }, {
      headers: { 'cache-control': 'public, max-age=0' },
    })
    .times(times);
}

beforeAll(async () => {
  fetchMock.activate();
  fetchMock.disableNetConnect();

  signing = (await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true,
    ['sign', 'verify'],
  )) as CryptoKeyPair;
  jwk = (await crypto.subtle.exportKey('jwk', signing.publicKey)) as JsonWebKey;
});

afterEach(() => fetchMock.assertNoPendingInterceptors());

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare('DELETE FROM devices'),
    env.DB.prepare('DELETE FROM rate_limits'),
  ]);
});

describe('signing in', () => {
  it('accepts a token Google signed for this app', async () => {
    interceptCerts();
    const response = await send(
      registerRequest({ platform: 'web', idToken: await signToken(goodClaims()) }),
    );

    expect(response.status).toBe(201);
    const body = (await response.json()) as { deviceToken: string };
    expect(body.deviceToken).toBeTruthy();
  });

  it('keeps the account out of the database in readable form', async () => {
    // The app needs to know that two devices are the same person. It does not
    // need to know who that is, and a row that cannot answer "whose is this?"
    // is one that cannot leak the answer.
    interceptCerts();
    await send(registerRequest({ platform: 'web', idToken: await signToken(goodClaims()) }));

    const row = await env.DB.prepare(
      'SELECT account_hash AS hash FROM devices',
    ).first<{ hash: string }>();

    expect(row?.hash).toBeTruthy();
    expect(row!.hash).not.toContain('1078349201');
    expect(row!.hash).not.toContain('someone@example.com');
    expect(row!.hash).toMatch(/^[0-9a-f]{64}$/);

    const stored = JSON.stringify(await env.DB.prepare('SELECT * FROM devices').first());
    expect(stored).not.toContain('someone@example.com');
    expect(stored).not.toContain('Someone');
  });

  it('gives one person one allowance across their devices', async () => {
    // Otherwise signing in on a phone and a laptop is two allowances, and
    // signing out and back in is a third.
    interceptCerts(2);
    const idToken = await signToken(goodClaims());

    const first = await send(registerRequest({ platform: 'web', idToken }));
    const second = await send(registerRequest({ platform: 'android', idToken }));

    expect(first.status).toBe(201);
    const tokenB = ((await second.json()) as { deviceToken: string }).deviceToken;

    // The allowance is keyed on the account now, not on either device.
    const accountHash = await sha256Hex('google:1078349201');
    const shared = env.QUOTA.get(env.QUOTA.idFromName(accountHash));
    await runInDurableObject(shared, async (q: QuotaCounter) => {
      await q.spend('voice', Math.floor(Date.now() / 1000));
    });

    const seenByB = await send(
      new Request(`${BASE}/v1/quota`, {
        headers: { authorization: `Bearer ${tokenB}`, 'cf-connecting-ip': '10.71.0.1' },
      }),
    );
    const quota = (await seenByB.json()) as { voice: number };
    expect(quota.voice).toBe(Number(env.VOICE_SESSIONS_PER_DAY) - 1);
  });

  it('still registers an anonymous device when nobody signs in', async () => {
    // No interceptor: a call to Google here would fail against
    // disableNetConnect, which is the point — it must not make one.
    const response = await send(registerRequest({ platform: 'web' }));
    expect(response.status).toBe(201);
  });
});

describe('tokens it refuses', () => {
  it('one signed by somebody else', async () => {
    // The whole attack: mint your own key pair, sign whatever claims you like.
    const impostor = (await crypto.subtle.generateKey(
      { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
      true,
      ['sign', 'verify'],
    )) as CryptoKeyPair;

    const header = b64url(JSON.stringify({ alg: 'RS256', kid: KID, typ: 'JWT' }));
    const payload = b64url(JSON.stringify(goodClaims()));
    const signature = new Uint8Array(
      await crypto.subtle.sign(
        'RSASSA-PKCS1-v1_5',
        impostor.privateKey,
        new TextEncoder().encode(`${header}.${payload}`),
      ),
    );

    interceptCerts();
    const response = await send(
      registerRequest({ platform: 'web', idToken: `${header}.${payload}.${b64url(signature)}` }),
    );
    expect(response.status).toBe(401);
  });

  it('one issued to a different application', async () => {
    // A validly signed Google token for someone else's app is still validly
    // signed. Without the audience check, their users are our users.
    interceptCerts();
    const response = await send(
      registerRequest({
        platform: 'web',
        idToken: await signToken(goodClaims({ aud: '999.apps.googleusercontent.com' })),
      }),
    );
    expect(response.status).toBe(401);
  });

  it('one that has expired', async () => {
    interceptCerts();
    const response = await send(
      registerRequest({
        platform: 'web',
        idToken: await signToken(
          goodClaims({ exp: Math.floor(Date.now() / 1000) - 3600 }),
        ),
      }),
    );
    expect(response.status).toBe(401);
  });

  it('one from an issuer that is not Google', async () => {
    interceptCerts();
    const response = await send(
      registerRequest({
        platform: 'web',
        idToken: await signToken(goodClaims({ iss: 'https://accounts.example.com' })),
      }),
    );
    expect(response.status).toBe(401);
  });

  it('one that says it needs no signature', async () => {
    // alg: none is the oldest JWT trick there is.
    const header = b64url(JSON.stringify({ alg: 'none', kid: KID, typ: 'JWT' }));
    const payload = b64url(JSON.stringify(goodClaims()));
    const response = await send(
      registerRequest({ platform: 'web', idToken: `${header}.${payload}.` }),
    );
    expect(response.status).toBe(401);
  });

  it('one signed with a key Google does not publish', async () => {
    interceptCerts();
    const response = await send(
      registerRequest({ platform: 'web', idToken: await signToken(goodClaims(), { kid: 'not-a-real-kid' }) }),
    );
    expect(response.status).toBe(401);
  });

  it('something that is not a token at all', async () => {
    for (const junk of ['', 'abc', 'a.b', 'a.b.c.d', '...']) {
      const response = await send(registerRequest({ platform: 'web', idToken: junk }));
      expect([201, 401]).toContain(response.status);
      // The empty string means "did not sign in", which registers anonymously.
      if (junk !== '') expect(response.status, junk).toBe(401);
    }
  });

  it('says nothing about which check failed', async () => {
    // Telling somebody probing this which test they failed tells them which
    // one to work on next.
    interceptCerts();
    const expired = await send(
      registerRequest({
        platform: 'web',
        idToken: await signToken(goodClaims({ exp: 1 })),
      }),
    );
    const body = (await expired.json()) as { error: string; message: string };
    expect(body.error).toBe('sign_in_rejected');
    expect(body.message).not.toMatch(/expired|audience|issuer|signature|key/i);
  });
});
