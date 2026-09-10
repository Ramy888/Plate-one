import { ADDITION_PHRASES } from './additions';
import { spendGlobal } from './budget';
import { authenticateDevice, quotaFor, recordEvent } from './device';
import { FOOD_NAMES } from './foods';
import { GeminiError, generateJson } from './gemini';
import { ApiError, json, readJson, requireString } from './http';
import { PLATE_SCHEMA, PLATE_SYSTEM, plateImagePrompt } from './prompts';
import { PREVIEW_DISCLAIMER } from './preview';

/**
 * Writes up and draws a plate the engine has already decided on.
 *
 * The whole design of this file exists to keep one promise: **no free text from
 * the user ever reaches a model here.** The caller sends catalogue ids; this
 * Worker looks them up in a generated closed set; the picture prompt is a fixed
 * template over the names it found. There is no interpolation point where a
 * spoken or typed sentence could reach the image model, which is the only
 * version of this that survives contact with someone trying.
 *
 * The recommendation itself is not generated at all — the engine on the device
 * chose it before this was called. This is a caption and a picture of a
 * decision that has already been made, and the model's own opinion about which
 * foods were involved is discarded.
 */

/** Flux tops out at 8. Four is the model's default and reads fine at this size. */
const IMAGE_STEPS = 4;

const now = () => Math.floor(Date.now() / 1000);

interface PlateReply {
  reply?: string;
  foodIds?: unknown;
  additionId?: unknown;
}

export async function postPlate(request: Request, env: Env): Promise<Response> {
  const t = now();
  const device = await authenticateDevice(request, env, t);

  const body = await readJson(request);
  const rawFoods = Array.isArray(body.foodIds) ? body.foodIds : [];
  const foodIds = rawFoods.filter((id): id is string => typeof id === 'string').slice(0, 12);
  const unknown = foodIds.find((id) => !(id in FOOD_NAMES));
  if (unknown !== undefined) {
    throw new ApiError(400, 'invalid_food', 'That is not a food this app knows.');
  }

  const additionId = requireString(body, 'additionId', { max: 64 });
  if (!(additionId in ADDITION_PHRASES)) {
    throw new ApiError(400, 'invalid_addition', 'That is not a food this app suggests.');
  }

  // The deployment's budget first, then this device's own.
  await spendGlobal(env, t);

  const stub = quotaFor(env, device.id);
  const spend = await stub.spend('preview', t);
  if (!spend.ok) {
    throw new ApiError(
      402,
      'quota_exhausted',
      'You have used today’s pictures. The suggestion itself is unlimited.',
    );
  }

  const plate =
    foodIds.length > 0
      ? foodIds.map((id) => FOOD_NAMES[id]).join(', ')
      : 'a simple everyday meal';
  const prompt = `On the plate: ${plate}.\nAdding: ${ADDITION_PHRASES[additionId]}.`;

  const started = Date.now();
  let result: PlateReply;
  try {
    result = await generateJson<PlateReply>(env, {
      model: env.MODEL_CHAT,
      system: PLATE_SYSTEM,
      schema: PLATE_SCHEMA,
      prompt,
    });
  } catch (error) {
    await stub.refund('preview', t);
    await recordEvent(
      env,
      {
        deviceId: device.id,
        kind: 'plate',
        model: env.MODEL_CHAT,
        durationMs: Date.now() - started,
        outcome: 'error',
      },
      t,
    );
    if (error instanceof GeminiError && error.status === 422) {
      throw new ApiError(422, 'plate_blocked', 'That plate could not be written up.');
    }
    throw new ApiError(503, 'plate_unavailable', 'Busy right now. Try again shortly.');
  }

  const reply = String(result.reply ?? '').slice(0, 800);

  // The picture is a bonus. A failure here still returns the words, the same
  // way a failed preview leaves the patch untouched.
  let imageUrl: string | null = null;
  const imagePrompt = plateImagePrompt(
    foodIds.map((id) => FOOD_NAMES[id]),
    ADDITION_PHRASES[additionId],
  );
  try {
    const drawn = (await env.AI.run(env.MODEL_CHAT_IMAGE as never, {
      prompt: imagePrompt,
      steps: IMAGE_STEPS,
    } as never)) as { image?: string };

    if (drawn?.image) {
      const bytes = Uint8Array.from(atob(drawn.image), (c) => c.charCodeAt(0));
      const key = `p/${crypto.randomUUID()}.jpg`;
      await env.PREVIEWS.put(key, bytes, {
        httpMetadata: { contentType: 'image/jpeg' },
        // Travels with the object, so the label cannot be separated from it.
        customMetadata: { disclaimer: PREVIEW_DISCLAIMER, createdAt: String(t) },
      });
      imageUrl = `${new URL(request.url).origin}/v1/preview/${encodeURIComponent(key.slice(2))}`;
    }
  } catch {
    // Deliberately swallowed: the reply is the product, the picture is not.
    imageUrl = null;
  }

  await recordEvent(
    env,
    {
      deviceId: device.id,
      kind: 'plate',
      model: env.MODEL_CHAT,
      durationMs: Date.now() - started,
      outcome: 'ok',
    },
    t,
  );

  return json({
    messageId: crypto.randomUUID(),
    reply,
    foodIds,
    additionId,
    imageUrl,
    disclaimer: PREVIEW_DISCLAIMER,
    quota: spend.quota,
  });
}
