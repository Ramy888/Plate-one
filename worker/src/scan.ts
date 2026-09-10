import { spendGlobal } from './budget';
import { authenticateDevice, quotaFor, recordEvent } from './device';
import { GeminiError, generateJson } from './gemini';
import { ApiError, json } from './http';
import { RECOGNITION_SCHEMA, RECOGNITION_SYSTEM } from './prompts';

/**
 * Recognition.
 *
 * The model reports what it can see. It does not choose the suggestions — the
 * app's own rule engine does that, using the same deterministic, preference-
 * aware logic the manual builder uses. That keeps the recommendation testable
 * and means a model outage degrades to tapping tiles rather than to nothing.
 */

/**
 * The client already compresses to 300 KB. This is headroom, not the budget,
 * so a slightly-over image is accepted rather than bounced.
 */
const MAX_IMAGE_BYTES = 400 * 1024;
const ALLOWED_TYPES = new Set(['image/jpeg', 'image/png', 'image/webp']);

interface RecognitionResponse {
  foods: { name: string; confidence: number }[];
  components: {
    protein: string;
    fibre: string;
    healthy_fat: string;
  };
}

const now = () => Math.floor(Date.now() / 1000);

async function readImage(request: Request): Promise<{ bytes: Uint8Array; mimeType: string }> {
  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    throw new ApiError(400, 'invalid_body', 'Expected a multipart upload.');
  }

  const file = form.get('image');
  if (!(file instanceof File)) {
    throw new ApiError(400, 'missing_image', 'No photo was attached.');
  }
  if (file.size > MAX_IMAGE_BYTES) {
    throw new ApiError(413, 'image_too_large', 'That photo is too large to send.');
  }
  if (file.size === 0) {
    throw new ApiError(400, 'empty_image', 'That photo was empty.');
  }

  const mimeType = file.type || 'image/jpeg';
  if (!ALLOWED_TYPES.has(mimeType)) {
    throw new ApiError(415, 'unsupported_type', 'Send a JPEG or PNG.');
  }

  return { bytes: new Uint8Array(await file.arrayBuffer()), mimeType };
}

/**
 * Maps a Gemini failure onto something the app can act on. The distinction
 * that matters to the user is "try again" versus "build it by hand instead".
 */
function describeFailure(error: unknown): ApiError {
  if (error instanceof GeminiError) {
    if (error.status === 422) {
      return new ApiError(
        422,
        'not_a_meal',
        'That photo could not be read as a meal. Try another, or build the meal by hand.',
      );
    }
    if (error.retryable) {
      return new ApiError(
        503,
        'recognition_busy',
        'Recognition is busy right now. Try again in a moment, or build the meal by hand.',
      );
    }
  }
  return new ApiError(
    502,
    'recognition_failed',
    'Recognition did not work. You can still build the meal by hand.',
  );
}

export async function postScan(request: Request, env: Env): Promise<Response> {
  const t = now();
  const device = await authenticateDevice(request, env, t);
  const { bytes, mimeType } = await readImage(request);

  // The deployment's budget first, then this device's own. In that order: a
  // device should not have a scan debited against it by a service that was
  // never going to answer.
  await spendGlobal(env, t);

  const stub = quotaFor(env, device.id);
  const spend = await stub.spend('scan', t);
  if (!spend.ok) {
    throw new ApiError(
      402,
      'quota_exhausted',
      'You have used today’s scans. A few more tomorrow — and tapping the meal '
        + 'and picking the food is unlimited.',
    );
  }

  const started = Date.now();
  let result: RecognitionResponse;
  try {
    result = await generateJson<RecognitionResponse>(env, {
      model: env.MODEL_VISION,
      system: RECOGNITION_SYSTEM,
      schema: RECOGNITION_SCHEMA,
      image: bytes,
      mimeType,
    });
  } catch (error) {
    // Our failure, not theirs — give the scan back.
    await stub.refund('scan', t);
    await recordEvent(
      env,
      {
        deviceId: device.id,
        kind: 'scan',
        model: env.MODEL_VISION,
        durationMs: Date.now() - started,
        outcome: 'error',
      },
      t,
    );
    throw describeFailure(error);
  }

  const foods = (result.foods ?? [])
    .filter((f) => typeof f.name === 'string' && f.name.trim() !== '')
    .map((f) => ({
      name: f.name.trim().slice(0, 60),
      confidence: Math.max(0, Math.min(1, Number(f.confidence) || 0)),
    }));

  const durationMs = Date.now() - started;

  if (foods.length === 0) {
    // A working call that found nothing still cost us, but charging someone a
    // scan for a photo the model could not read would be indefensible. The
    // per-IP limit is what stops this being abused.
    await stub.refund('scan', t);
    await recordEvent(
      env,
      {
        deviceId: device.id,
        kind: 'scan',
        model: env.MODEL_VISION,
        durationMs,
        outcome: 'empty',
      },
      t,
    );
    throw new ApiError(
      422,
      'no_food_found',
      'No food was recognised. Try a clearer photo, or build the meal by hand.',
    );
  }

  await recordEvent(
    env,
    {
      deviceId: device.id,
      kind: 'scan',
      model: env.MODEL_VISION,
      durationMs,
      outcome: 'ok',
      matched: foods.length,
    },
    t,
  );

  return json({
    scanId: crypto.randomUUID(),
    foods,
    components: {
      protein: result.components?.protein ?? 'uncertain',
      fibre: result.components?.fibre ?? 'uncertain',
      healthyFat: result.components?.healthy_fat ?? 'uncertain',
    },
    quota: spend.quota,
  });
}
