import { ADDITION_PHRASES } from './additions';
import { spendGlobal } from './budget';
import { authenticateDevice, quotaForDeviceRow, recordEvent } from './device';
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

  // An empty addition means "just the meal". The voice screen draws the plate
  // as the conversation fills it in, before anything has been suggested.
  const rawAddition = body.additionId;
  const additionId =
    rawAddition === undefined || rawAddition === null || rawAddition === ''
      ? ''
      : requireString(body, 'additionId', { max: 64 });
  if (additionId !== '' && !(additionId in ADDITION_PHRASES)) {
    throw new ApiError(400, 'invalid_addition', 'That is not a food this app suggests.');
  }

  // The same plate drawn twice is the same picture. Under the voice screen the
  // user flips between three suggestions on one meal, and without this each
  // flip back would cost another image and another fifteen seconds.
  const cacheKey = await plateCacheKey(foodIds, additionId);
  const cached = await env.PREVIEWS.get(cacheKey);
  if (cached) {
    const stored = cached.customMetadata ?? {};
    return json({
      messageId: crypto.randomUUID(),
      reply: stored.reply ?? '',
      foodIds,
      additionId,
      imageUrl: previewUrlFor(request, cacheKey),
      disclaimer: PREVIEW_DISCLAIMER,
      quota: (await quotaForDeviceRow(env, device).peek(t)),
      cached: true,
    });
  }

  // The deployment's budget first, then this device's own.
  await spendGlobal(env, t);

  const stub = quotaForDeviceRow(env, device);
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
  const prompt =
    additionId === ''
      ? `On the plate: ${plate}.\nNothing is being added yet; just say what the meal is.`
      : `On the plate: ${plate}.\nAdding: ${ADDITION_PHRASES[additionId]}.`;

  const started = Date.now();

  // A plate with nothing added to it needs no caption. Nothing displays one —
  // the words are about the addition, and there is not one yet — so asking a
  // model to write it is a second round trip for something nobody reads.
  let reply = '';
  if (additionId !== '') {
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
    reply = String(result.reply ?? '').slice(0, 800);
  }

  // The picture is a bonus. A failure here still returns the words, the same
  // way a failed preview leaves the patch untouched.
  let imageUrl: string | null = null;
  const imagePrompt = plateImagePrompt(
    foodIds.map((id) => FOOD_NAMES[id]),
    additionId === '' ? null : ADDITION_PHRASES[additionId],
  );
  try {
    const drawn = (await env.AI.run(env.MODEL_CHAT_IMAGE as never, {
      prompt: imagePrompt,
      steps: IMAGE_STEPS,
    } as never)) as { image?: string };

    if (drawn?.image) {
      const bytes = Uint8Array.from(atob(drawn.image), (c) => c.charCodeAt(0));
      // Stored under the content key, so the next request for this plate is a
      // lookup rather than another fifteen seconds and another image.
      await env.PREVIEWS.put(cacheKey, bytes, {
        httpMetadata: { contentType: 'image/jpeg' },
        // Travels with the object, so the label cannot be separated from it.
        // The caption rides along too — a cache hit has to return both.
        customMetadata: { disclaimer: PREVIEW_DISCLAIMER, createdAt: String(t), reply },
      });
      imageUrl = previewUrlFor(request, cacheKey);
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
    cached: false,
  });
}

/**
 * A stable name for one plate.
 *
 * Food order is not part of the plate — "rice and chicken" and "chicken and
 * rice" are one meal and must not be drawn twice — so the ids are sorted
 * before hashing. The result lives in the same `p/` prefix as everything else,
 * so the bucket's 24-hour lifecycle rule expires it without anything here
 * having to remember to.
 */
async function plateCacheKey(foodIds: string[], additionId: string): Promise<string> {
  const canonical = `${[...foodIds].sort().join(',')}|${additionId}`;
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(canonical));
  const hex = [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
  return `p/plate-${hex.slice(0, 32)}.jpg`;
}

function previewUrlFor(request: Request, key: string): string {
  return `${new URL(request.url).origin}/v1/preview/${encodeURIComponent(key.slice(2))}`;
}
