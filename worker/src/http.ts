/** Request parsing, validation and response shaping. */

export const MAX_BODY_BYTES = 64 * 1024;

/** Errors the client is allowed to see, with the status they carry. */
export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

export function json(data: unknown, status = 200, extraHeaders: HeadersInit = {}): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
      'referrer-policy': 'no-referrer',
      ...extraHeaders,
    },
  });
}

export function noContent(): Response {
  return new Response(null, { status: 204, headers: { 'cache-control': 'no-store' } });
}

export function errorResponse(error: unknown): Response {
  if (error instanceof ApiError) {
    return json({ error: error.code, message: error.message }, error.status);
  }
  // Never leak an internal message to the client; the log keeps the detail.
  console.error('unhandled', { message: String(error) });
  return json({ error: 'internal', message: 'Something went wrong. Please try again.' }, 500);
}

/**
 * Reads a JSON body with a hard size cap. Content-Length is a hint, so the
 * decoded text is checked too — a chunked body can lie about its length.
 */
export async function readJson(request: Request): Promise<Record<string, unknown>> {
  const declared = Number(request.headers.get('content-length') ?? '0');
  if (declared > MAX_BODY_BYTES) {
    throw new ApiError(413, 'body_too_large', 'That request was too large.');
  }
  const text = await request.text();
  if (text.length > MAX_BODY_BYTES) {
    throw new ApiError(413, 'body_too_large', 'That request was too large.');
  }
  if (text.trim() === '') return {};
  try {
    const parsed = JSON.parse(text);
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new ApiError(400, 'invalid_body', 'Expected a JSON object.');
    }
    return parsed as Record<string, unknown>;
  } catch (e) {
    if (e instanceof ApiError) throw e;
    throw new ApiError(400, 'invalid_json', 'That request body was not valid JSON.');
  }
}

export function requireString(
  body: Record<string, unknown>,
  field: string,
  { min = 1, max = 1000 }: { min?: number; max?: number } = {},
): string {
  const value = body[field];
  if (typeof value !== 'string') {
    throw new ApiError(400, 'missing_field', `${field} is required.`);
  }
  const trimmed = value.trim();
  if (trimmed.length < min || trimmed.length > max) {
    throw new ApiError(400, 'invalid_field', `${field} is not a valid length.`);
  }
  return trimmed;
}

export function bearerToken(request: Request): string {
  const header = request.headers.get('authorization') ?? '';
  const match = /^Bearer\s+(\S+)$/i.exec(header);
  if (!match) {
    // Not an account — this is the anonymous device token. There is nothing to
    // sign into, so the message says what to do rather than who to be.
    throw new ApiError(401, 'unauthorized', 'This device is not registered.');
  }
  return match[1];
}

/** Cloudflare sets this and it cannot be spoofed by the client. */
export function clientIp(request: Request): string {
  return request.headers.get('cf-connecting-ip') ?? 'unknown';
}
