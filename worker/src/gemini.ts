import { toBase64 } from './crypto';

/**
 * The only place the Gemini key is used.
 *
 * Routes through AI Gateway when one is configured, which adds per-request
 * logging, cost analytics and a rate ceiling in front of a paid API. Falls back
 * to calling Google directly so the Worker is useful before the gateway exists;
 * the key stays server-side either way.
 */

export class GeminiError extends Error {
  constructor(
    readonly status: number,
    readonly retryable: boolean,
    message: string,
  ) {
    super(message);
  }
}

function endpoint(env: Env, model: string): string {
  const path = `v1beta/models/${model}:generateContent`;
  if (env.AI_GATEWAY_ID) {
    return `https://gateway.ai.cloudflare.com/v1/${env.CF_ACCOUNT_ID}/${env.AI_GATEWAY_ID}/google-ai-studio/${path}`;
  }
  return `https://generativelanguage.googleapis.com/${path}`;
}

interface GeminiPart {
  text?: string;
  inlineData?: { mimeType: string; data: string };
}

interface GeminiResponse {
  candidates?: { content?: { parts?: GeminiPart[] } }[];
  promptFeedback?: { blockReason?: string };
}

/**
 * One call, with retries.
 *
 * Gemini returns 503 under load often enough that a single attempt is not good
 * enough; 429 means the account is over quota and retrying briefly is still
 * worth one go before giving up.
 */
async function call(
  env: Env,
  model: string,
  body: unknown,
  { attempts = 3, timeoutMs = 30_000 } = {},
): Promise<GeminiResponse> {
  let lastError: GeminiError | null = null;

  for (let attempt = 0; attempt < attempts; attempt++) {
    let response: Response;
    try {
      response = await fetch(endpoint(env, model), {
        method: 'POST',
        headers: {
          'x-goog-api-key': env.GEMINI_API_KEY,
          'content-type': 'application/json',
        },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch (error) {
      lastError = new GeminiError(504, true, `network: ${String(error)}`);
      if (attempt < attempts - 1) {
        await sleep(600 * (attempt + 1));
        continue;
      }
      throw lastError;
    }

    if (response.ok) return (await response.json()) as GeminiResponse;

    const detail = (await response.text()).slice(0, 300);
    const retryable = response.status === 503 || response.status === 429;
    lastError = new GeminiError(response.status, retryable, detail);

    // Logged with the status but not the body, which can echo the request.
    console.warn(
      JSON.stringify({ event: 'gemini_error', model, status: response.status, attempt }),
    );

    if (!retryable || attempt === attempts - 1) throw lastError;
    await sleep(600 * (attempt + 1));
  }

  throw lastError ?? new GeminiError(500, false, 'unreachable');
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Structured JSON out of an image, some text, or both. The schema is enforced
 * by the API, so what comes back is shaped even when the model is confused.
 */
export async function generateJson<T>(
  env: Env,
  {
    model,
    system,
    schema,
    image,
    mimeType,
    prompt,
  }: {
    model: string;
    system: string;
    schema: unknown;
    image?: Uint8Array;
    mimeType?: string;
    prompt?: string;
  },
): Promise<T> {
  const parts: Array<Record<string, unknown>> = [];
  if (image) {
    parts.push({ inlineData: { mimeType: mimeType ?? 'image/jpeg', data: toBase64(image) } });
  }
  if (prompt) parts.push({ text: prompt });
  if (parts.length === 0) throw new GeminiError(500, false, 'nothing to send');

  const response = await call(env, model, {
    systemInstruction: { parts: [{ text: system }] },
    contents: [{ parts }],
    generationConfig: {
      responseMimeType: 'application/json',
      responseSchema: schema,
      // Deterministic: the same plate should describe the same way twice.
      temperature: 0,
    },
  });

  if (response.promptFeedback?.blockReason) {
    throw new GeminiError(422, false, `blocked: ${response.promptFeedback.blockReason}`);
  }
  const text = response.candidates?.[0]?.content?.parts?.find((p) => p.text)?.text;
  if (!text) throw new GeminiError(502, true, 'no text in response');

  try {
    return JSON.parse(text) as T;
  } catch {
    throw new GeminiError(502, true, 'response was not valid JSON');
  }
}

/** An edited image. Returns the raw bytes and their type. */
export async function generateImage(
  env: Env,
  {
    model,
    instruction,
    image,
    mimeType,
  }: { model: string; instruction: string; image: Uint8Array; mimeType: string },
): Promise<{ bytes: Uint8Array; mimeType: string }> {
  const response = await call(
    env,
    model,
    {
      contents: [
        {
          parts: [
            { inlineData: { mimeType, data: toBase64(image) } },
            { text: instruction },
          ],
        },
      ],
    },
    // Image generation is slower than recognition; one retry, longer patience.
    { attempts: 2, timeoutMs: 90_000 },
  );

  if (response.promptFeedback?.blockReason) {
    throw new GeminiError(422, false, `blocked: ${response.promptFeedback.blockReason}`);
  }
  const part = response.candidates?.[0]?.content?.parts?.find((p) => p.inlineData);
  if (!part?.inlineData) throw new GeminiError(502, true, 'no image in response');

  const binary = atob(part.inlineData.data);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return { bytes, mimeType: part.inlineData.mimeType };
}
