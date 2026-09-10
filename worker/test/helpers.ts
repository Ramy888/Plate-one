import { env } from 'cloudflare:test';

/**
 * The Durable Object holding a device's allowance.
 *
 * There are no accounts: a device token hashes to a device row, and the device
 * id is what the allowance is keyed on. Tests reach it directly rather than
 * through the API so they can assert the arithmetic, not just the message.
 */
export async function quotaForDevice(deviceToken: string) {
  const hash = await sha256Hex(deviceToken);
  const row = await env.DB.prepare('SELECT id FROM devices WHERE token_hash = ?')
    .bind(hash)
    .first<{ id: string }>();
  if (!row) throw new Error('no device for that token — register one first');
  return env.QUOTA.get(env.QUOTA.idFromName(row.id));
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
