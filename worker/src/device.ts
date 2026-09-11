import { randomToken, sha256Hex } from './crypto';
import { ApiError, bearerToken } from './http';
import type { QuotaCounter, QuotaView } from './quota';

/**
 * Anonymous device identity.
 *
 * This is not an account. There is no email, no password and nothing to sign
 * into — a device gets an opaque token on first launch so the server can hold
 * a quota against something. Deleting the device deletes everything the server
 * knows.
 */

export interface DeviceRow {
  id: string;
  platform: string;

  /// SHA-256 of the Google subject, when somebody signed in. Null otherwise.
  accountHash?: string | null;
}

const PLATFORMS = new Set(['android', 'ios', 'web']);

export function normalizePlatform(value: unknown): string {
  const platform = typeof value === 'string' ? value.toLowerCase() : '';
  if (!PLATFORMS.has(platform)) {
    throw new ApiError(400, 'invalid_platform', 'platform must be android, ios or web.');
  }
  return platform;
}

export async function registerDevice(
  env: Env,
  platform: string,
  now: number,
  accountHash: string | null = null,
): Promise<{ token: string; device: DeviceRow }> {
  const token = randomToken();
  const device: DeviceRow = { id: crypto.randomUUID(), platform, accountHash };
  await env.DB.prepare(
    `INSERT INTO devices (id, token_hash, platform, created_at, last_seen_at, account_hash)
     VALUES (?, ?, ?, ?, ?, ?)`,
  )
    .bind(device.id, await sha256Hex(token), platform, now, now, accountHash)
    .run();
  return { token, device };
}

/**
 * Resolves the bearer token to a device. Also refreshes `last_seen_at`, which
 * is the only thing that lets abandoned devices be swept later.
 */
export async function authenticateDevice(
  request: Request,
  env: Env,
  now: number,
): Promise<DeviceRow> {
  const token = bearerToken(request);
  const row = await env.DB.prepare(
    'SELECT id, platform, account_hash AS accountHash FROM devices WHERE token_hash = ?',
  )
    .bind(await sha256Hex(token))
    .first<DeviceRow>();

  if (!row) {
    throw new ApiError(401, 'unknown_device', 'This device is not registered.');
  }
  await env.DB.prepare('UPDATE devices SET last_seen_at = ? WHERE id = ?')
    .bind(now, row.id)
    .run();
  return row;
}

/** The Durable Object holding this device's allowance. */
export function quotaFor(env: Env, deviceId: string): DurableObjectStub<QuotaCounter> {
  return env.QUOTA.get(env.QUOTA.idFromName(deviceId));
}

/**
 * The allowance for whoever is making this call.
 *
 * Keyed on the account when there is one, so signing in on a second device
 * does not hand out a second allowance — and signing out and back in does not
 * either. Without an account it falls back to the device, which is what a
 * deployment with sign-in switched off gets.
 */
export function quotaForDeviceRow(env: Env, device: DeviceRow): DurableObjectStub<QuotaCounter> {
  return quotaFor(env, device.accountHash ?? device.id);
}

export async function forgetDevice(env: Env, device: DeviceRow): Promise<void> {
  await quotaForDeviceRow(env, device).forget();

  await env.DB.batch([
    env.DB.prepare('DELETE FROM reports WHERE device_id = ?').bind(device.id),
    env.DB.prepare('DELETE FROM scan_events WHERE device_id = ?').bind(device.id),
    env.DB.prepare('DELETE FROM devices WHERE id = ?').bind(device.id),
  ]);
}

/** Records an attempt. Counts only — never what the meal was. */
export async function recordEvent(
  env: Env,
  fields: {
    deviceId: string;
    kind: 'plate' | 'voice';
    model: string;
    durationMs: number;
    outcome: 'ok' | 'empty' | 'error';
    matched?: number;
    unmatched?: number;
  },
  now: number,
): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO scan_events
       (id, device_id, kind, created_at, model, duration_ms, outcome, matched_count, unmatched_count)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      crypto.randomUUID(),
      fields.deviceId,
      fields.kind,
      now,
      fields.model,
      fields.durationMs,
      fields.outcome,
      fields.matched ?? 0,
      fields.unmatched ?? 0,
    )
    .run();
}

export type { QuotaView };
