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
