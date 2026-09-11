import { sha256Hex } from './crypto';
import { authenticateDevice, quotaForDeviceRow } from './device';
import { ApiError, json, readJson, requireString } from './http';

/**
 * Promo codes.
 *
 * Somebody who has used today's conversations should have a way back in that
 * is not "come back tomorrow" — a judge trying the app, someone being shown it
 * across a table. A code is that way back.
 *
 * **The codes live in a secret, never in this repository.** The repo is public
 * and MIT licensed: a list of codes in the client, in a migration, or in a
 * seed file is a free-credits giveaway to everybody who reads it. Even hashes
 * would not do — a short code has few enough possibilities to walk through.
 *
 * `PROMO_CODES` is `CODE:grants` pairs, comma separated:
 *
 *     wrangler secret put PROMO_CODES
 *     PLATE-7QK2M:5,PLATE-J4XR9:5
 *
 * Redemptions are recorded per person, so one code cannot be spent twice by
 * the same account, and a code's total use is capped by `PROMO_USES_PER_CODE`.
 */

const now = () => Math.floor(Date.now() / 1000);

/** Codes are typed by hand, from a screen or a card. Treat them loosely. */
function normalize(code: string): string {
  return code.trim().toUpperCase().replace(/\s+/g, '');
}

interface Offer {
  grants: number;
}

function offers(env: Env): Map<string, Offer> {
  const out = new Map<string, Offer>();
  for (const entry of (env.PROMO_CODES ?? '').split(',')) {
    const [code, grants] = entry.split(':');
    if (!code || !code.trim()) continue;
    const n = Number(grants);
    out.set(normalize(code), { grants: Number.isFinite(n) && n > 0 ? n : 5 });
  }
  return out;
}

/**
 * Constant-time comparison, by looking the code up as a *hash*.
 *
 * A Map lookup on the plaintext would be fine in practice — these are not
 * secrets worth timing — but hashing both sides costs nothing and means the
 * plaintext is never a key that could end up in a log line or a heap dump.
 */
async function find(env: Env, code: string): Promise<{ code: string; grants: number } | null> {
  const wanted = await sha256Hex(normalize(code));
  for (const [known, offer] of offers(env)) {
    if ((await sha256Hex(known)) === wanted) return { code: known, grants: offer.grants };
  }
  return null;
}

export async function postPromo(request: Request, env: Env): Promise<Response> {
  const t = now();
  const device = await authenticateDevice(request, env, t);

  const body = await readJson(request);
  const typed = requireString(body, 'code', { max: 64 });

  const offer = await find(env, typed);
  // A wrong code and an unconfigured deployment look the same from outside.
  // There is nothing useful a caller does differently, and the difference is
  // worth something to somebody guessing.
  if (!offer) {
    throw new ApiError(404, 'promo_unknown', 'That code is not one we know.');
  }

  const redeemer = device.id;
  const codeHash = await sha256Hex(offer.code);

  // The primary key on (code_hash, redeemer) is what actually enforces this;
  // the check below only turns a constraint violation into a sentence. Both
  // are here because the exception path is the one that runs under a race.
  const already = await env.DB.prepare(
    'SELECT 1 FROM promo_redemptions WHERE code_hash = ? AND redeemer = ?',
  )
    .bind(codeHash, redeemer)
    .first();
  if (already) {
    throw new ApiError(409, 'promo_used', 'You have already used that code.');
  }

  const maxUses = Number(env.PROMO_USES_PER_CODE ?? 1);
  const used = await env.DB.prepare(
    'SELECT COUNT(*) AS n FROM promo_redemptions WHERE code_hash = ?',
  )
    .bind(codeHash)
    .first<{ n: number }>();
  if ((used?.n ?? 0) >= maxUses) {
    throw new ApiError(409, 'promo_spent', 'That code has already been used.');
  }

  // Recorded before the grant. If the insert loses a race the unique key
  // refuses it, and the grant that would have doubled it never happens.
  try {
    await env.DB.prepare(
      'INSERT INTO promo_redemptions (code_hash, redeemer, redeemed_at) VALUES (?, ?, ?)',
    )
      .bind(codeHash, redeemer, t)
      .run();
  } catch {
    throw new ApiError(409, 'promo_used', 'You have already used that code.');
  }

  const quota = await quotaForDeviceRow(env, device).grant(t, {
    // A code is worth this many more tries.
    plates: offer.grants,
    voice: offer.grants,
    // Each try redraws the meal as it is described and again for each
    // suggestion tried — twenty-odd pictures in a talkative one — so a code
    // granting only tries would run out of pictures inside the first.
    previews: offer.grants * 25,
  });

  return json({ granted: offer.grants, quota });
}
