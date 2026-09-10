/**
 * Cross-origin access, for the one client that needs it.
 *
 * Plate One's Application URL is a web page, and it is served from a different
 * origin than this Worker. Without these headers a browser refuses every call
 * before it is sent — the app looks offline and the Worker's log stays empty,
 * which is a miserable thing to debug.
 *
 * It is an allowlist rather than `*`. Not because CORS protects the device
 * token — it does not, and anyone can register a device from a terminal — but
 * because `*` lets any page on the internet spend this deployment's budget
 * through its own visitors' browsers. The global cap is the real defence; this
 * keeps casual use of it down to the sites we meant.
 */

/** Origins allowed to call the API from a browser. Comma-separated. */
function allowed(env: Env): string[] {
  return (env.ALLOWED_ORIGINS ?? '')
    .split(',')
    .map((origin: string) => origin.trim())
    .filter((origin: string) => origin !== '');
}

/**
 * The headers for this request's origin, or none if it is not on the list.
 *
 * A request with no `Origin` header — curl, a native app, another server — is
 * not a browser request and needs nothing added.
 */
export function corsHeaders(request: Request, env: Env): Record<string, string> {
  const origin = request.headers.get('origin');
  if (!origin) return {};

  // Vary regardless of the outcome: the response for one origin must never be
  // served from a cache to another.
  const vary = { vary: 'Origin' };
  if (!allowed(env).includes(origin)) return vary;

  return {
    ...vary,
    'access-control-allow-origin': origin,
    // No cookies, no `Authorization` implicit credentials — the device token is
    // sent explicitly by our own code. Allowing credentials would widen this
    // for nothing.
    'access-control-expose-headers': 'retry-after',
  };
}

/**
 * Answers the browser's preflight.
 *
 * Returns null when this is not one, so the router can carry on.
 */
export function preflight(request: Request, env: Env): Response | null {
  if (request.method !== 'OPTIONS') return null;
  if (!request.headers.get('access-control-request-method')) return null;

  const headers = corsHeaders(request, env);
  // An origin that is not on the list gets a plain refusal rather than a
  // helpful one. There is nothing to negotiate.
  if (!headers['access-control-allow-origin']) {
    return new Response(null, { status: 403, headers });
  }

  return new Response(null, {
    status: 204,
    headers: {
      ...headers,
      'access-control-allow-methods': 'GET, POST, DELETE, OPTIONS',
      'access-control-allow-headers': 'authorization, content-type',
      // A day. The preflight is pure overhead on every call otherwise.
      'access-control-max-age': '86400',
    },
  });
}

/** Copies a response, adding this request's CORS headers. */
export function withCors(
  response: Response,
  request: Request,
  env: Env,
): Response {
  const headers = corsHeaders(request, env);
  if (Object.keys(headers).length === 0) return response;

  const merged = new Headers(response.headers);
  for (const [key, value] of Object.entries(headers)) merged.set(key, value);
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: merged,
  });
}
