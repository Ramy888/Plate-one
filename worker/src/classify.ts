import { spendGlobal } from './budget';
import { authenticateDevice } from './device';
import { ApiError, json, readJson } from './http';

/**
 * Describing a food the catalogue does not contain.
 *
 * Somebody says "pancakes". There is no pancake in the catalogue, so nothing
 * matched, the plate stayed empty, and the app asked what was in it — which is
 * how an app that has never heard of breakfast sounds. Asking the person to
 * list flour and eggs is worse: it puts eggs and milk on the plate, and then
 * both the advice and the picture are about a meal nobody ate.
 *
 * The engine never needed the name. It reasons over protein, fibre and fat plus
 * a few tags, so an unknown food only has to be *described* in that vocabulary
 * to be treated exactly like a catalogue one.
 *
 * Three things keep this from becoming a hole:
 *
 *  - The answer is filtered against a **fixed** vocabulary. Scores are clamped
 *    to 0-3; a tag or a group the app does not already use is dropped. A
 *    confident invention cannot introduce a new concept.
 *  - The name that comes back is the model's, not the caller's, and it is what
 *    a picture may be drawn from. Nothing the user typed reaches an image
 *    prompt — the client sends an id and the Worker looks the name up here.
 *  - It describes what is *on* the plate. It never names the suggestion; that
 *    list stays sealed, because the suggestion is the advice somebody acts on.
 *
 * Cached by name, so the second sighting is the first one's answer. That is
 * what keeps "the same plate gives the same options" true with a model in the
 * loop at all.
 */

/** Exactly the tags the catalogue uses. Anything else is dropped. */
const TAGS = new Set([
  'carb', 'dairy', 'drink', 'egg', 'fish', 'gluten', 'gluten_free',
  'meat', 'nuts', 'plant', 'sweet', 'vegetarian',
]);

/** Exactly the groups the catalogue uses. */
const GROUPS = new Set(['dairy', 'dishes', 'drinks', 'fruit', 'grains', 'protein', 'sweets', 'veg']);

/** How many unknown foods one call will describe. A plate is not a shopping list. */
const MAX_NAMES = 6;

const MODEL = '@cf/meta/llama-3.3-70b-instruct-fp8-fast';

const SYSTEM = `You describe a dish in nutrition terms for a recommendation engine.

For each food you are given, answer with:
- name: the dish in at most three plain words, no punctuation
- protein, fibre, fat: whole numbers 0 to 3, where 0 is none and 3 is a lot for
  one normal serving
- tags: any of carb, dairy, drink, egg, fish, gluten, gluten_free, meat, nuts,
  plant, sweet, vegetarian
- group: one of dairy, dishes, drinks, fruit, grains, protein, sweets, veg

Describe the dish as eaten. Pancakes are a grain dish, not eggs and milk.
Never describe anything that is not a food.`;

export interface Described {
  id: string;
  name: string;
  protein: number;
  fibre: number;
  fat: number;
  tags: string[];
  group: string;
}

const key = (name: string) => name.trim().toLowerCase().slice(0, 60);

/** The id the client carries about and the plate route resolves. */
export const describedId = (nameKey: string) => `d:${nameKey}`;

const clamp = (value: unknown): number => {
  const n = Math.round(Number(value));
  return Number.isFinite(n) ? Math.min(3, Math.max(0, n)) : 0;
};

/** The model's own words, reduced to something an image prompt may carry. */
function safeName(value: unknown, fallback: string): string {
  const words = String(value ?? '')
    .toLowerCase()
    .replace(/[^a-z\s]/g, ' ')
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 3);
  const name = words.join(' ');
  return name.length >= 3 ? name : fallback;
}

export async function lookupDescribed(env: Env, ids: string[]): Promise<Map<string, string>> {
  const keys = ids.filter((id) => id.startsWith('d:')).map((id) => id.slice(2));
  if (keys.length === 0) return new Map();

  const marks = keys.map(() => '?').join(', ');
  const { results } = await env.DB.prepare(
    `SELECT name_key, name FROM food_descriptions WHERE name_key IN (${marks})`,
  )
    .bind(...keys)
    .all<{ name_key: string; name: string }>();

  return new Map(results.map((row) => [describedId(row.name_key), row.name]));
}

export async function postClassify(request: Request, env: Env): Promise<Response> {
  const t = Math.floor(Date.now() / 1000);
  await authenticateDevice(request, env, t);

  const body = await readJson(request);
  const asked = Array.isArray(body.names)
    ? body.names.filter((n: unknown): n is string => typeof n === 'string')
    : [];
  const names = [...new Set(asked.map(key).filter((n) => n.length >= 2))].slice(0, MAX_NAMES);
  if (names.length === 0) return json({ described: [] });

  // Cache first. A described food is only described once, which is what keeps
  // the same plate giving the same answer.
  const marks = names.map(() => '?').join(', ');
  const { results: cached } = await env.DB.prepare(
    `SELECT * FROM food_descriptions WHERE name_key IN (${marks})`,
  )
    .bind(...names)
    .all<{
      name_key: string; name: string; protein: number; fibre: number;
      fat: number; tags: string; food_group: string;
    }>();

  const described: Described[] = cached.map((row) => ({
    id: describedId(row.name_key),
    name: row.name,
    protein: row.protein,
    fibre: row.fibre,
    fat: row.fat,
    tags: row.tags ? row.tags.split(',') : [],
    group: row.food_group,
  }));

  const missing = names.filter((n) => !cached.some((row) => row.name_key === n));
  if (missing.length === 0) return json({ described });

  await spendGlobal(env, t);

  let answer: { foods?: unknown[] };
  try {
    const run = await env.AI.run(MODEL, {
      messages: [
        { role: 'system', content: SYSTEM },
        { role: 'user', content: `Describe: ${missing.join(', ')}` },
      ],
      response_format: {
        type: 'json_schema',
        json_schema: {
          type: 'object',
          properties: {
            foods: {
              type: 'array',
              items: {
                type: 'object',
                properties: {
                  asked: { type: 'string' },
                  name: { type: 'string' },
                  protein: { type: 'integer' },
                  fibre: { type: 'integer' },
                  fat: { type: 'integer' },
                  tags: { type: 'array', items: { type: 'string' } },
                  group: { type: 'string' },
                },
                required: ['asked', 'name', 'protein', 'fibre', 'fat', 'tags', 'group'],
              },
            },
          },
          required: ['foods'],
        },
      },
    });
    answer = (typeof run === 'object' && run !== null && 'response' in run
      ? (run as { response: unknown }).response
      : run) as { foods?: unknown[] };
  } catch (error) {
    // Best effort. A plate with one unknown food on it is no worse off than it
    // was before this existed.
    console.error(JSON.stringify({ event: 'classify_failed', message: String(error).slice(0, 140) }));
    return json({ described });
  }

  const rows = Array.isArray(answer?.foods) ? answer.foods : [];
  const writes = [];
  for (const raw of rows) {
    if (typeof raw !== 'object' || raw === null) continue;
    const row = raw as Record<string, unknown>;
    const nameKey = key(String(row.asked ?? ''));
    if (!missing.includes(nameKey)) continue;   // only what was asked for

    const entry: Described = {
      id: describedId(nameKey),
      name: safeName(row.name, nameKey),
      protein: clamp(row.protein),
      fibre: clamp(row.fibre),
      fat: clamp(row.fat),
      tags: (Array.isArray(row.tags) ? row.tags : [])
        .map((tag) => String(tag).toLowerCase())
        .filter((tag) => TAGS.has(tag)),
      group: GROUPS.has(String(row.group)) ? String(row.group) : 'dishes',
    };
    described.push(entry);
    writes.push(
      env.DB.prepare(
        `INSERT OR REPLACE INTO food_descriptions
         (name_key, name, protein, fibre, fat, tags, food_group, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      ).bind(nameKey, entry.name, entry.protein, entry.fibre, entry.fat,
             entry.tags.join(','), entry.group, t),
    );
  }
  if (writes.length > 0) await env.DB.batch(writes);

  return json({ described });
}
