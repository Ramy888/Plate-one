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
  /** Plates kept. One a day, and keeping one is what ends the try. */
  platesUsed: number;
  previewsUsed: number;
  voiceUsed: number;
  /** Unix seconds at which the current counting window opened. */
  windowStart: number;

  /**
   * Extra allowance from a redeemed promo code, on top of the daily one.
   *
   * Survives the daily reset rather than being wiped by it: someone handed a
   * code at nine in the evening should still have it in the morning.
   */
  bonusPlates?: number;
  bonusPreviews?: number;
  bonusVoice?: number;
}

/** What the app is told. Enough to render the right screen without guessing. */
export interface QuotaView {
  /**
   * Free tries left. A try is the whole journey — talk, be recommended
   * something, see it drawn — and keeping the plate is what spends it.
   */
  plates: number;

  /** What is left today, not what has been spent. */
  previews: number;
  /** Voice sessions. The main feature, so the most generous of the three. */
  voice: number;
  resetsAt: number;

  /** Whether any of this came from a redeemed code, so the app can say so. */
  bonus?: boolean;
}

const DAY = 24 * 60 * 60;

/** Daily caps per device. A spend ceiling, not a monetisation lever. */
export const PLATES_PER_DAY = 1;
export const PREVIEWS_PER_DAY = 10;
export const VOICE_SESSIONS_PER_DAY = 30;

/** The things that cost money, and the only things counted here. */
export type Spend = 'plate' | 'preview' | 'voice';

const EMPTY: QuotaState = {
  platesUsed: 0,
  previewsUsed: 0,
  voiceUsed: 0,
  windowStart: 0,
  bonusPlates: 0,
  bonusPreviews: 0,
  bonusVoice: 0,
};

export class QuotaCounter extends DurableObject<Env> {
  private get platesPerDay(): number {
    return Number(this.env.PLATES_PER_DAY ?? PLATES_PER_DAY);
  }

  private get previewsPerDay(): number {
    return Number(this.env.PREVIEWS_PER_DAY ?? PREVIEWS_PER_DAY);
  }

  private get voicePerDay(): number {
    return Number(this.env.VOICE_SESSIONS_PER_DAY ?? VOICE_SESSIONS_PER_DAY);
  }

  private async load(now: number): Promise<QuotaState> {
    const stored = (await this.ctx.storage.get<QuotaState>('state')) ?? { ...EMPTY };

    if (stored.windowStart === 0 || now - stored.windowStart >= DAY) {
      const next: QuotaState = {
        ...EMPTY,
        windowStart: now,
        // The day resets; what somebody was given does not. Wiping a code at
        // midnight would make handing one out in the evening close to useless.
        bonusPlates: stored.bonusPlates ?? 0,
        bonusPreviews: stored.bonusPreviews ?? 0,
        bonusVoice: stored.bonusVoice ?? 0,
      };
      await this.ctx.storage.put('state', next);
      return next;
    }
    // `voiceUsed` arrived after the first devices did, so a row written before
    // it existed has no such field. Default it rather than propagating NaN
    // through the arithmetic.
    return { ...EMPTY, ...stored };
  }

  private view(state: QuotaState): QuotaView {
    const bonusPlates = state.bonusPlates ?? 0;
    const bonusPreviews = state.bonusPreviews ?? 0;
    const bonusVoice = state.bonusVoice ?? 0;
    return {
      plates: Math.max(0, this.platesPerDay + bonusPlates - state.platesUsed),
      previews: Math.max(0, this.previewsPerDay + bonusPreviews - state.previewsUsed),
      voice: Math.max(0, this.voicePerDay + bonusVoice - state.voiceUsed),
      resetsAt: state.windowStart + DAY,
      bonus: bonusPlates > 0 || bonusVoice > 0 || bonusPreviews > 0,
    };
  }

  private static spent(state: QuotaState, kind: Spend, by: number): QuotaState {
    return {
      ...state,
      platesUsed: state.platesUsed + (kind === 'plate' ? by : 0),
      previewsUsed: state.previewsUsed + (kind === 'preview' ? by : 0),
      voiceUsed: state.voiceUsed + (kind === 'voice' ? by : 0),
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
  async spend(kind: Spend, now: number): Promise<{ ok: boolean; quota: QuotaView }> {
    const state = await this.load(now);
    const before = this.view(state);
    if (before[kind === 'plate' ? 'plates' : kind === 'preview' ? 'previews' : 'voice'] <= 0) {
      return { ok: false, quota: before };
    }

    const next = QuotaCounter.spent(state, kind, 1);
    await this.ctx.storage.put('state', next);
    return { ok: true, quota: this.view(next) };
  }

  /**
   * Gives a spent unit back. Called when the model errors after the quota was
   * taken — the user should not pay for our failure.
   */
  async refund(kind: Spend, now: number): Promise<void> {
    const state = await this.load(now);
    const given = QuotaCounter.spent(state, kind, -1);
    await this.ctx.storage.put('state', {
      ...given,
      // A refund must never mint allowance out of nothing.
      platesUsed: Math.max(0, given.platesUsed),
      previewsUsed: Math.max(0, given.previewsUsed),
      voiceUsed: Math.max(0, given.voiceUsed),
    });
  }

  /**
   * Adds allowance from a redeemed promo code.
   *
   * The caller has already checked that the code is real and that this person
   * has not used it before; this only does the arithmetic.
   */
  async grant(
    now: number,
    { plates = 0, voice = 0, previews = 0 }: { plates?: number; voice?: number; previews?: number },
  ): Promise<QuotaView> {
    const state = await this.load(now);
    const next: QuotaState = {
      ...state,
      bonusPlates: (state.bonusPlates ?? 0) + plates,
      bonusVoice: (state.bonusVoice ?? 0) + voice,
      bonusPreviews: (state.bonusPreviews ?? 0) + previews,
    };
    await this.ctx.storage.put('state', next);
    return this.view(next);
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
