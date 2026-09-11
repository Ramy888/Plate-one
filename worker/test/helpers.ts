import { env, fetchMock } from 'cloudflare:test';

/**
 * The Durable Object holding a device's allowance.
 *
 * Keyed on the account when somebody signed in, and on the device otherwise —
 * the same rule the routes use, so a test reaching in directly sees what they
 * see. Tests go around the API here so they can assert the arithmetic rather
 * than only the message.
 */
export async function quotaForDevice(deviceToken: string) {
  const hash = await sha256Hex(deviceToken);
  const row = await env.DB.prepare(
    'SELECT id, account_hash AS accountHash FROM devices WHERE token_hash = ?',
  )
    .bind(hash)
    .first<{ id: string; accountHash: string | null }>();
  if (!row) throw new Error('no device for that token — register one first');
  return env.QUOTA.get(env.QUOTA.idFromName(row.accountHash ?? row.id));
}

/**
 * The single Durable Object holding the whole deployment's daily budget — the
 * real one the routes spend from.
 *
 * Read it, never drain it. Storage isolation is off (see vitest.config.ts), so
 * this instance is shared by every suite in the run: a test that emptied it
 * would refuse every request in every file that ran afterwards, and the failure
 * would surface far from its cause. Arithmetic goes through [scratchCap].
 */
export function globalCap() {
  return env.GLOBAL_CAP.get(env.GLOBAL_CAP.idFromName('all'));
}

/** A throwaway budget, for tests that need to spend one to the end. */
export function scratchCap(name: string) {
  return env.GLOBAL_CAP.get(env.GLOBAL_CAP.idFromName(`scratch:${name}`));
}

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// ------------------------------------------------------------------ sign-in
//
// A real RSA key pair, so the suites that need a signed-in device exercise the
// actual signature path rather than a stub of it. Generated once per run.

const GOOGLE = 'https://www.googleapis.com';
const KID = 'test-key-1';

let pair: CryptoKeyPair | null = null;
let publicJwk: JsonWebKey | null = null;

async function signer() {
  if (pair && publicJwk) return { pair, publicJwk };
  pair = (await crypto.subtle.generateKey(
    {
      name: 'RSASSA-PKCS1-v1_5',
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: 'SHA-256',
    },
    true,
    ['sign', 'verify'],
  )) as CryptoKeyPair;
  publicJwk = (await crypto.subtle.exportKey('jwk', pair.publicKey)) as JsonWebKey;
  return { pair, publicJwk };
}

function b64url(value: Uint8Array | string): string {
  const binary = typeof value === 'string' ? value : String.fromCharCode(...value);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** Serves our public key where Google's live. One interceptor per lookup. */
export async function interceptGoogleCerts(times = 1) {
  const { publicJwk } = await signer();
  fetchMock
    .get(GOOGLE)
    .intercept({ path: (p: string) => p.startsWith('/oauth2/v3/certs'), method: 'GET' })
    .reply(200, { keys: [{ ...publicJwk, kid: KID, alg: 'RS256', use: 'sig' }] }, {
      headers: { 'cache-control': 'public, max-age=0' },
    })
    .times(times);
}

/** A Google ID token for this deployment's audience. */
export async function googleIdToken(
  claims: Record<string, unknown> = {},
  { kid = KID, alg = 'RS256' } = {},
): Promise<string> {
  const { pair } = await signer();
  const seconds = Math.floor(Date.now() / 1000);
  const payload = {
    iss: 'https://accounts.google.com',
    aud: env.GOOGLE_CLIENT_ID,
    sub: '1078349201',
    exp: seconds + 3600,
    iat: seconds,
    ...claims,
  };
  const header = b64url(JSON.stringify({ alg, kid, typ: 'JWT' }));
  const body = b64url(JSON.stringify(payload));
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      'RSASSA-PKCS1-v1_5',
      pair.privateKey,
      new TextEncoder().encode(`${header}.${body}`),
    ),
  );
  return `${header}.${body}.${b64url(signature)}`;
}
