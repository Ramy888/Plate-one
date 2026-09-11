import { ApiError } from './http';

/**
 * Verifying a Google ID token, here rather than by asking Google.
 *
 * The token is an RS256 JWT. Google publishes the public keys that signed it,
 * so the signature can be checked locally: one cached fetch instead of a round
 * trip on every sign-in, and no dependence on an endpoint being up at the
 * moment somebody opens the app.
 *
 * Three things are checked, and all three matter:
 *
 * - **The signature**, against Google's current keys. Without it a token is a
 *   base64 string anybody can type.
 * - **`aud`**, against our own client id. A validly signed token issued to a
 *   *different* application is still a valid Google token — accepting one lets
 *   any other app's users in as ours.
 * - **`exp`**, with a small allowance for clocks that disagree.
 *
 * What comes back is the subject and nothing else. The email and the name are
 * in the token too, and the client displays them, but the server has no use
 * for them and does not keep them.
 */

const CERTS_URL = 'https://www.googleapis.com/oauth2/v3/certs';
const ISSUERS = new Set(['accounts.google.com', 'https://accounts.google.com']);

/** Clocks disagree. A minute is generous and still far short of an hour. */
const CLOCK_SKEW_SECONDS = 60;

interface GoogleKey {
  kid: string;
  n: string;
  e: string;
  alg?: string;
  kty?: string;
  use?: string;
}

/**
 * Google's signing keys, cached for as long as Google says.
 *
 * Module scope, so it survives between requests on a warm isolate and costs
 * nothing on a cold one. Keys rotate roughly daily; `cache-control` on the
 * response is the authority on when to look again.
 */
let cachedKeys: { keys: GoogleKey[]; until: number } | null = null;

async function signingKeys(now: number): Promise<GoogleKey[]> {
  if (cachedKeys && cachedKeys.until > now) return cachedKeys.keys;

  const response = await fetch(CERTS_URL);
  if (!response.ok) {
    throw new ApiError(503, 'sign_in_unavailable', 'Could not check that sign-in. Try again shortly.');
  }
  const body = (await response.json()) as { keys?: GoogleKey[] };
  const keys = body.keys ?? [];

  const maxAge = Number(/max-age=(\d+)/.exec(response.headers.get('cache-control') ?? '')?.[1]);
  cachedKeys = {
    keys,
    // An hour if Google did not say, which it always does. A max-age of zero
    // means zero, not the default — treating "do not cache" as "cache for an
    // hour" is how a rotated key keeps being trusted after it was withdrawn.
    until: now + (Number.isFinite(maxAge) ? maxAge : 3600),
  };
  return keys;
}

/** Base64url to bytes. JWTs are base64url, which is not what atob expects. */
function fromBase64Url(value: string): Uint8Array {
  const padded = value.replace(/-/g, '+').replace(/_/g, '/');
  const binary = atob(padded + '='.repeat((4 - (padded.length % 4)) % 4));
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

function decodeJson(part: string): Record<string, unknown> {
  return JSON.parse(new TextDecoder().decode(fromBase64Url(part))) as Record<string, unknown>;
}

const refused = () =>
  new ApiError(401, 'sign_in_rejected', 'That sign-in could not be verified. Try again.');

/**
 * Checks a Google ID token and returns the account it identifies.
 *
 * Throws [ApiError] for anything wrong with the token — there is nothing a
 * caller can usefully do differently, and saying which check failed tells
 * whoever is probing which one to work on next.
 */
export async function verifyGoogleIdToken(
  env: Env,
  idToken: string,
  now: number,
): Promise<{ subject: string }> {
  const clientId = env.GOOGLE_CLIENT_ID;
  if (!clientId) {
    throw new ApiError(503, 'sign_in_unconfigured', 'Sign-in is not configured on this server.');
  }

  const parts = idToken.split('.');
  if (parts.length !== 3) throw refused();

  let header: Record<string, unknown>;
  let claims: Record<string, unknown>;
  try {
    header = decodeJson(parts[0]);
    claims = decodeJson(parts[1]);
  } catch {
    throw refused();
  }

  if (header.alg !== 'RS256') throw refused();

  const key = (await signingKeys(now)).find((k) => k.kid === header.kid);
  if (!key) throw refused();

  const publicKey = await crypto.subtle.importKey(
    'jwk',
    { kty: 'RSA', n: key.n, e: key.e, alg: 'RS256', ext: true },
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['verify'],
  );

  const signed = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
  const ok = await crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5',
    publicKey,
    fromBase64Url(parts[2]),
    signed,
  );
  if (!ok) throw refused();

  // A validly signed token issued to someone else's app is still validly
  // signed. This is the check that makes it ours.
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!audiences.includes(clientId)) throw refused();

  if (!ISSUERS.has(String(claims.iss))) throw refused();

  const expires = Number(claims.exp);
  if (!Number.isFinite(expires) || expires + CLOCK_SKEW_SECONDS < now) throw refused();

  const subject = String(claims.sub ?? '');
  if (subject === '') throw refused();

  return { subject };
}
