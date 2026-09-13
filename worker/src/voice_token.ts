import { refundVoice, spendGlobal, spendVoice } from './budget';
import { authenticateDevice, quotaForDeviceRow, recordEvent } from './device';
import { ApiError, json } from './http';

/**
 * Mints a single-use AssemblyAI Voice Agent token for one browser session.
 *
 * This route exists for one reason: **the API key must never reach the client.**
 * A browser cannot set an `Authorization` header on a WebSocket, so the key
 * cannot travel with the connection even if we wanted it to. AssemblyAI's answer
 * is a short-lived token minted server-side and passed as a query parameter —
 * so this Worker spends the key, and the client spends the token.
 *
 * The audio itself never comes here. The browser opens its socket straight to
 * AssemblyAI, which is both faster and one less place a recording of someone's
 * dinner could be sitting.
 *
 * Verified against https://www.assemblyai.com/docs/voice-agents/voice-agent-api/browser-integration
 * on 2026-09-10. Note the Bearer prefix: the Voice Agent API wants one, and
 * AssemblyAI's other products do not.
 */

const TOKEN_ENDPOINT = 'https://agents.assemblyai.com/v1/token';

/**
 * How long the client has to redeem the token. Long enough to survive a slow
 * page and a microphone permission prompt, short enough that one intercepted
 * from a log is worthless by the time anyone reads it. Allowed range is 1–600.
 */
const EXPIRES_IN_SECONDS = 120;

/**
 * The ceiling on one conversation. AssemblyAI's own default is three hours,
 * which is three hours of billing for a tab someone left open.
 *
 * Three minutes. A plate takes well under one — describe the meal, hear the
 * suggestion, try the other two — and this is the number the whole budget
 * multiplies by: the audio never comes through this Worker, so session length
 * at mint time is the only bound there is on what a conversation can cost. The
 * client runs the same clock and ends the session itself, so reaching it looks
 * like tapping End rather than a dropped connection.
 */
const MAX_SESSION_SECONDS = 180;

const now = () => Math.floor(Date.now() / 1000);

export async function postVoiceToken(request: Request, env: Env): Promise<Response> {
  const t = now();
  const device = await authenticateDevice(request, env, t);

  if (!env.ASSEMBLYAI_API_KEY) {
    // Said plainly rather than reported as a mysterious 503: a deployment
    // missing its key is a configuration mistake, and it should look like one.
    throw new ApiError(
      503,
      'voice_unconfigured',
      'Voice is not configured on this server.',
    );
  }

  // A try has to be open before anybody starts talking. Speaking is free to
  // us, but a conversation with no plate at the end of it is a conversation
  // that cannot finish — better to say so at the microphone than three minutes
  // in, when somebody has described their dinner to nothing.
  const stub = quotaForDeviceRow(env, device);
  const open = await stub.peek(t);
  if (open.plates <= 0) {
    throw new ApiError(
      402,
      'try_used',
      'Today’s free plate is used. A promo code opens another, and building a meal by hand is unlimited.',
    );
  }

  // The deployment's budgets first, then this device's own — a device should
  // not be debited by a service that was never going to answer. The voice
  // budget is the one denominated in somebody else's money, and it is spent
  // before the mint rather than after, so two callers arriving together cannot
  // both find the last session free.
  await spendGlobal(env, t);
  await spendVoice(env, t);

  const spend = await stub.spend('voice', t);
  if (!spend.ok) {
    // This caller is out, but the deployment is not: hand the day's session
    // back so somebody else can have it. Refusing one person must not also
    // quietly cost everybody else a conversation.
    await refundVoice(env, t);
    throw new ApiError(
      402,
      'quota_exhausted',
      'You have used today’s conversations. A few more tomorrow — and tapping '
        + 'the meal and picking the food is unlimited.',
    );
  }

  const url = new URL(TOKEN_ENDPOINT);
  url.searchParams.set('expires_in_seconds', String(EXPIRES_IN_SECONDS));
  url.searchParams.set('max_session_duration_seconds', String(MAX_SESSION_SECONDS));

  const started = Date.now();
  let token: string;
  try {
    const response = await fetch(url, {
      headers: { authorization: `Bearer ${env.ASSEMBLYAI_API_KEY}` },
      signal: AbortSignal.timeout(10_000),
    });

    if (!response.ok) {
      // The upstream body may quote our own request back at us. Log the status,
      // never the body, and tell the client nothing it could learn from.
      console.error(JSON.stringify({ event: 'voice_token_failed', status: response.status }));
      throw new ApiError(503, 'voice_unavailable', 'Voice is busy. Try again shortly.');
    }

    const body = (await response.json()) as { token?: unknown };
    if (typeof body.token !== 'string' || body.token === '') {
      throw new ApiError(503, 'voice_unavailable', 'Voice is busy. Try again shortly.');
    }
    token = body.token;
  } catch (error) {
    // The session never happened, so it must not be charged for. This is in a
    // catch rather than a finally because the success path deliberately keeps
    // the unit spent.
    await stub.refund('voice', t);
    await refundVoice(env, t);
    await recordEvent(
      env,
      {
        deviceId: device.id,
        kind: 'voice',
        model: 'assemblyai-voice-agent',
        durationMs: Date.now() - started,
        outcome: 'error',
      },
      t,
    );
    if (error instanceof ApiError) throw error;
    throw new ApiError(503, 'voice_unavailable', 'Voice is busy. Try again shortly.');
  }

  await recordEvent(
    env,
    {
      deviceId: device.id,
      kind: 'voice',
      model: 'assemblyai-voice-agent',
      durationMs: Date.now() - started,
      outcome: 'ok',
    },
    t,
  );

  return json({
    token,
    // The client needs both to decide whether to re-mint before connecting.
    expiresAt: t + EXPIRES_IN_SECONDS,
    maxSessionSeconds: MAX_SESSION_SECONDS,
    quota: spend.quota,
  });
}
