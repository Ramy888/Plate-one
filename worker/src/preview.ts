import { authenticateDevice } from './device';
import { ApiError } from './http';

/**
 * Generated pictures, and the label that has to travel with them.
 *
 * Plates are drawn in `plate.ts` and written to R2, which deletes them after 24
 * hours by a lifecycle rule. This file owns the disclaimer they carry and the
 * one route that reads them back.
 */

const now = () => Math.floor(Date.now() / 1000);

/**
 * Attached to every generated image, and returned with every response. A
 * generated photograph of food that reads as real is exactly what an app
 * store's AI policy is watching for.
 */
export const PREVIEW_DISCLAIMER =
  'AI visual preview — appearance and serving size are illustrative.';

/** The same sentence, for an HTTP header, which cannot carry an em dash. */
export const PREVIEW_DISCLAIMER_ASCII = PREVIEW_DISCLAIMER.replace('—', '-');

/**
 * Serves a generated picture.
 *
 * The bucket has no public access, so this is the only way to read one, and the
 * object disappears within 24 hours.
 *
 * The name is a hash of the catalogue ids the plate was drawn from, which makes
 * it guessable on purpose — that is what makes it a cache. There is nothing
 * personal in one: it is a stock picture of rice and chicken, identical for
 * everyone who describes that meal, and reading it still needs a device token.
 */
export async function getPreview(request: Request, env: Env): Promise<Response> {
  await authenticateDevice(request, env, now());

  const name = new URL(request.url).pathname.split('/').pop() ?? '';
  if (!/^plate-[0-9a-f]{32}\.jpg$/.test(name)) {
    throw new ApiError(400, 'bad_key', 'Not a picture.');
  }

  const object = await env.PREVIEWS.get(`p/${name}`);
  if (!object) {
    throw new ApiError(
      404,
      'preview_expired',
      'That picture has expired. Pictures are kept for 24 hours.',
    );
  }

  return new Response(object.body, {
    headers: {
      'content-type': object.httpMetadata?.contentType ?? 'image/jpeg',
      'cache-control': 'private, max-age=900',
      'x-ai-generated': 'true',
      'x-disclaimer': PREVIEW_DISCLAIMER_ASCII,
    },
  });
}
