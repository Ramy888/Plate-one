/**
 * The Plate One API.
 *
 * Holds the model keys, enforces allowances that a patched client cannot lie
 * its way past, and proxies the calls that cost money. It stores no
 * photographs and no meal data — what anyone ate stays on their own device.
 *
 * There are no accounts here. A device gets an anonymous id, that id carries a
 * daily allowance, and the deployment as a whole carries a ceiling on top of
 * it — because this is a public demo URL with a finite budget behind it.
 */
import { globalCap } from './budget';
import { preflight, withCors } from './cors';
import { authenticateDevice, forgetDevice, normalizePlatform, quotaFor, registerDevice } from './device';
import {
  ApiError,
  clientIp,
  errorResponse,
  json,
  noContent,
  readJson,
  requireString,
} from './http';
import { postPlate } from './plate';
import { getPreview } from './preview';
import { postVoiceToken } from './voice_token';

export { GlobalCap, QuotaCounter } from './quota';

const now = () => Math.floor(Date.now() / 1000);

const REPORT_REASONS = new Set(['wrong_food', 'offensive', 'unrealistic', 'other']);

// ---------------------------------------------------------------- limiting

/** Coarse per-IP ceiling, on top of the per-device quota. */
async function enforceLimit(
  env: Env,
  key: string,
  limit: number,
  windowSeconds: number,
): Promise<void> {
  const t = now();
  const bucket = `${key}:${Math.floor(t / windowSeconds)}`;
  const row = await env.DB.prepare(
    `INSERT INTO rate_limits (bucket, count, expires_at) VALUES (?, 1, ?)
     ON CONFLICT(bucket) DO UPDATE SET count = count + 1
     RETURNING count`,
  )
    .bind(bucket, t + windowSeconds)
    .first<{ count: number }>();

  if ((row?.count ?? 1) > limit) {
    throw new ApiError(429, 'rate_limited', 'Too many requests. Try again shortly.');
  }
}

async function sweep(env: Env): Promise<void> {
  const t = now();
  await env.DB.batch([
    env.DB.prepare('DELETE FROM rate_limits WHERE expires_at < ?').bind(t),
  ]);
}

// -------------------------------------------------------------------- routes

async function postDevice(request: Request, env: Env): Promise<Response> {
  await enforceLimit(env, `register:${clientIp(request)}`, 10, 3600);

  const body = await readJson(request);
  const platform = normalizePlatform(body.platform);

  const { token, device } = await registerDevice(env, platform, now());
  const quota = await quotaFor(env, device.id).peek(now());
  return json({ deviceToken: token, quota }, 201);
}

async function getQuota(request: Request, env: Env): Promise<Response> {
  const device = await authenticateDevice(request, env, now());
  return json(await quotaFor(env, device.id).peek(now()));
}

async function deleteDevice(request: Request, env: Env): Promise<Response> {
  const device = await authenticateDevice(request, env, now());
  await forgetDevice(env, device);
  console.log(JSON.stringify({ event: 'device_forgotten', at: now() }));
  return noContent();
}

/**
 * Google Play requires apps that generate content to accept reports in-app.
 * This always returns 202: a user reporting something offensive must never see
 * an error, so failures are logged and swallowed.
 */
async function postReport(request: Request, env: Env): Promise<Response> {
  const device = await authenticateDevice(request, env, now());
  const body = await readJson(request);

  try {
    const targetType = requireString(body, 'targetType', { max: 16 });
    const targetId = requireString(body, 'targetId', { max: 64 });
    const reason = requireString(body, 'reason', { max: 32 });
    const note = typeof body.note === 'string' ? body.note.slice(0, 500) : null;

    await env.DB.prepare(
      `INSERT INTO reports (id, device_id, target_type, target_id, reason, note, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    )
      .bind(
        crypto.randomUUID(),
        device.id,
        targetType === 'preview' ? 'preview' : 'plate',
        targetId,
        REPORT_REASONS.has(reason) ? reason : 'other',
        note,
        now(),
      )
      .run();
  } catch (error) {
    console.error(JSON.stringify({ event: 'report_failed', message: String(error) }));
  }

  return json({ status: 'received' }, 202);
}

// -------------------------------------------------------------------- router

type Handler = (request: Request, env: Env) => Promise<Response>;

/// Writing up and drawing a plate the engine has already decided on: one model
/// call and one image. A per-IP ceiling on top of each device's own allowance,
/// because a device id is free to mint and an IP is not.
async function plateRoute(request: Request, env: Env): Promise<Response> {
  await enforceLimit(env, `plate:${clientIp(request)}`, 40, 3600);
  return postPlate(request, env);
}

// One voice session is one minted token. The per-IP ceiling is tighter than the
// others because a token is the cheapest thing here to ask for and the most
// expensive thing to be handed.
async function voiceTokenRoute(request: Request, env: Env): Promise<Response> {
  await enforceLimit(env, `voice:${clientIp(request)}`, 20, 3600);
  return postVoiceToken(request, env);
}

const ROUTES: Record<string, Partial<Record<string, Handler>>> = {
  '/v1/device': { POST: postDevice, DELETE: deleteDevice },
  '/v1/quota': { GET: getQuota },
  '/v1/report': { POST: postReport },
  '/v1/plate': { POST: plateRoute },
  '/v1/voice/token': { POST: voiceTokenRoute },
};

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    // Every response leaves through one door, so a route added later cannot
    // forget its CORS headers and fail only in a browser.
    return withCors(await handle(request, env, ctx), request, env);
  },
} satisfies ExportedHandler<Env>;

async function handle(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    const options = preflight(request, env);
    if (options) return options;

    if (url.pathname === '/health') {
      // Reported honestly, so a misconfigured or exhausted deployment is
      // obvious from the outside rather than discovered by a user.
      const budget = await globalCap(env).peek(now());
      return json({
        ok: true,
        budget,
        // Whether voice can work at all, without saying anything about the key.
        voice: env.ASSEMBLYAI_API_KEY ? 'configured' : 'unconfigured',
        models: { vision: env.MODEL_VISION, image: env.MODEL_IMAGE },
      });
    }

    // Generated pictures are served from a path with the object name in it,
    // so it cannot be a fixed route.
    if (url.pathname.startsWith('/v1/preview/') && request.method === 'GET') {
      try {
        return await getPreview(request, env);
      } catch (error) {
        return errorResponse(error);
      }
    }

    const route = ROUTES[url.pathname];
    if (!route) return json({ error: 'not_found', message: 'No such endpoint.' }, 404);

    const handler = route[request.method];
    if (!handler) {
      return json({ error: 'method_not_allowed', message: 'Wrong method.' }, 405, {
        allow: Object.keys(route).join(', '),
      });
    }

    try {
      const response = await handler(request, env);
      ctx.waitUntil(sweep(env).catch(() => {}));
      return response;
    } catch (error) {
      return errorResponse(error);
    }
}
