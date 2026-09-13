import { ApiError } from './http';
import type { GlobalCap } from './quota';

/**
 * The ceiling across every device.
 *
 * Per-device quotas stop one phone running up a bill. They do nothing about a
 * hundred phones, or one script rotating device ids — and this is a public demo
 * URL with a hackathon's credits behind it. Every route that costs money spends
 * one unit of this before it spends the caller's own allowance, so the worst
 * case is a day of degraded service rather than an empty API account.
 */
export function globalCap(env: Env): DurableObjectStub<GlobalCap> {
  return env.GLOBAL_CAP.get(env.GLOBAL_CAP.idFromName('all'));
}

/**
 * The ceiling on conversations, counted on its own.
 *
 * Voice is the one thing here billed by the minute, by somebody else, out of a
 * credit balance that does not refill. The general cap counts calls, and a call
 * is not a unit of money — two thousand of them is a fortune in voice and small
 * change in pictures. So conversations get their own budget, in the unit that
 * actually bounds the bill: sessions, each capped in length at the point the
 * token is minted.
 */
export function voiceCap(env: Env): DurableObjectStub<GlobalCap> {
  return env.GLOBAL_CAP.get(env.GLOBAL_CAP.idFromName('voice'));
}

/** How many conversations this deployment will start in a day, across everyone. */
export function voiceLimit(env: Env): number {
  return Number(env.GLOBAL_VOICE_SESSIONS_PER_DAY ?? 100);
}

/** Spends one unit of the deployment's daily budget, or refuses in plain words. */
export async function spendGlobal(env: Env, now: number): Promise<void> {
  const result = await globalCap(env).spend(now);
  if (result.ok) return;

  console.warn(JSON.stringify({ event: 'global_cap_reached', used: result.used, limit: result.limit }));
  throw new ApiError(
    429,
    'service_busy',
    'Plate One has answered as many questions as it can today. '
      + 'Tapping the meal and picking the food still works, and it always will.',
  );
}

/** Spends one conversation from the deployment's daily voice budget. */
export async function spendVoice(env: Env, now: number): Promise<void> {
  const result = await voiceCap(env).spend(now, voiceLimit(env));
  if (result.ok) return;

  console.warn(JSON.stringify({ event: 'voice_cap_reached', used: result.used, limit: result.limit }));
  throw new ApiError(
    429,
    'service_busy',
    'Plate One has held as many conversations as it can today. '
      + 'Tapping the meal and picking the food still works, and it always will.',
  );
}

/** Gives one back when the conversation never started. */
export async function refundVoice(env: Env, now: number): Promise<void> {
  await voiceCap(env).refund(now);
}
