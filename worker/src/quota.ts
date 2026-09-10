import { DurableObject } from 'cloudflare:workers';

/**
 * One instance per device: today's allowance for the calls that cost money.
 *
 * Spending is a read-modify-write, and doing it in D1 means two requests can
 * both read "1 left" and both spend it. A Durable Object is single-threaded per
 * id, so the race cannot happen — no transactions, no optimistic retries.
 *
 * There is no paid tier and no account. Everyone gets the same daily allowance,
 * counted against an anonymous device id, and the whole deployment is capped on
 * top of that (see `GlobalCap`) so one enthusiastic afternoon cannot empty the
 * account that pays for it. Building a meal by hand never touches this file,
 * never touches the network, and is free forever.
 */

export interface QuotaState {
  scansUsed: number;
  previewsUsed: number;
  /** Unix seconds at which the current counting window opened. */
  windowStart: number;
}

/** What the app is told. Enough to render the right screen without guessing. */
export interface QuotaView {
  /** What is left today, not what has been spent. */
  scans: number;
  previews: number;
  resetsAt: number;
}

const DAY = 24 * 60 * 60;

/** Daily caps per device. A spend ceiling, not a monetisation lever. */
export const SCANS_PER_DAY = 8;
export const PREVIEWS_PER_DAY = 4;

const EMPTY: QuotaState = { scansUsed: 0, previewsUsed: 0, windowStart: 0 };

export class QuotaCounter extends DurableObject<Env> {
  private get scansPerDay(): number {
    return Number(this.env.SCANS_PER_DAY ?? SCANS_PER_DAY);
  }

  private get previewsPerDay(): number {
    return Number(this.env.PREVIEWS_PER_DAY ?? PREVIEWS_PER_DAY);
  }

  private async load(now: number): Promise<QuotaState> {
    const stored = (await this.ctx.storage.get<QuotaState>('state')) ?? { ...EMPTY };

    if (stored.windowStart === 0 || now - stored.windowStart >= DAY) {
      const next: QuotaState = { scansUsed: 0, previewsUsed: 0, windowStart: now };
      await this.ctx.storage.put('state', next);
      return next;
    }
    return stored;
  }

  private view(state: QuotaState): QuotaView {
    return {
      scans: Math.max(0, this.scansPerDay - state.scansUsed),
      previews: Math.max(0, this.previewsPerDay - state.previewsUsed),
      resetsAt: state.windowStart + DAY,
    };
  }

  /** Current allowance without spending anything. */
  async peek(now: number): Promise<QuotaView> {
    return this.view(await this.load(now));
  }

  /**
   * Spends one unit if there is one. Returns the allowance either way, so a
   * refusal can still tell the caller why and when it changes.
   */
  async spend(kind: 'scan' | 'preview', now: number): Promise<{ ok: boolean; quota: QuotaView }> {
    const state = await this.load(now);
    const before = this.view(state);
    const available = kind === 'scan' ? before.scans : before.previews;
    if (available <= 0) return { ok: false, quota: before };

    const next: QuotaState = {
      ...state,
      scansUsed: state.scansUsed + (kind === 'scan' ? 1 : 0),
      previewsUsed: state.previewsUsed + (kind === 'preview' ? 1 : 0),
    };
    await this.ctx.storage.put('state', next);
    return { ok: true, quota: this.view(next) };
  }

  /**
   * Gives a spent unit back. Called when the model errors after the quota was
   * taken — the user should not pay for our failure.
   */
  async refund(kind: 'scan' | 'preview', now: number): Promise<void> {
    const state = await this.load(now);
    await this.ctx.storage.put('state', {
      ...state,
      scansUsed: Math.max(0, state.scansUsed - (kind === 'scan' ? 1 : 0)),
      previewsUsed: Math.max(0, state.previewsUsed - (kind === 'preview' ? 1 : 0)),
    });
  }

  /** Backs "delete my data" with something real. */
  async forget(): Promise<void> {
    await this.ctx.storage.deleteAll();
  }
}

/**
 * One instance for the whole deployment: the ceiling across every device.
 *
 * The per-device allowance stops one phone running up a bill. It does nothing
 * about a hundred phones, or one script rotating device ids. This is the thing
 * standing between a public demo URL and an empty API account, so it is
 * deliberately dumb: a count, a day, and a hard stop.
 */
export class GlobalCap extends DurableObject<Env> {
  private get perDay(): number {
    return Number(this.env.GLOBAL_CALLS_PER_DAY ?? 2000);
  }

  /** Spends one unit of the global budget. False means the deployment is done for today. */
  async spend(now: number): Promise<{ ok: boolean; used: number; limit: number; resetsAt: number }> {
    const stored = (await this.ctx.storage.get<{ used: number; windowStart: number }>('state')) ??
      { used: 0, windowStart: 0 };

    const fresh = stored.windowStart === 0 || now - stored.windowStart >= DAY;
    const state = fresh ? { used: 0, windowStart: now } : stored;
    const limit = this.perDay;

    if (state.used >= limit) {
      return { ok: false, used: state.used, limit, resetsAt: state.windowStart + DAY };
    }

    const next = { ...state, used: state.used + 1 };
    await this.ctx.storage.put('state', next);
    return { ok: true, used: next.used, limit, resetsAt: next.windowStart + DAY };
  }

  async peek(now: number): Promise<{ used: number; limit: number; resetsAt: number }> {
    const stored = (await this.ctx.storage.get<{ used: number; windowStart: number }>('state')) ??
      { used: 0, windowStart: 0 };
    const fresh = stored.windowStart === 0 || now - stored.windowStart >= DAY;
    const state = fresh ? { used: 0, windowStart: now } : stored;
    return { used: state.used, limit: this.perDay, resetsAt: state.windowStart + DAY };
  }
}
