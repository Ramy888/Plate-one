/**
 * The two model prompts, as fixed strings.
 *
 * Nothing a user types is ever interpolated into either of these. The only
 * variable is an addition name, and that comes from the app's own catalogue —
 * a closed set of 30 strings — so there is no injection surface.
 */

export const RECOGNITION_SYSTEM = `You are a food identification service for a nutrition app. You will receive one photograph of a meal.

Identify only the foods you can actually see. Be conservative: it is far better to omit an uncertain item than to invent one. Do not guess at ingredients hidden inside a dish; name the dish.

For each food, give a short everyday name a home cook would use ("rice", "grilled chicken", "green salad"), not a scientific or brand name.

Then judge whether the meal visibly contains each of three components:
- protein: meat, fish, eggs, dairy, beans, lentils, tofu, nuts
- fibre: vegetables, fruit, pulses, whole grains
- healthy_fat: oily fish, nuts, seeds, avocado, olive oil, tahini

Answer "present" only when you can see it, "possibly_missing" when you can see the meal clearly and it appears absent, and "uncertain" when the photograph does not let you tell.

Never estimate calories, weights, portions or nutritional values. Never describe any food as healthy, unhealthy, good or bad. Never comment on the person eating it.

If the image contains no food at all, return an empty foods array.`;

/** Enforced by the API, so a malformed response is impossible rather than unlikely. */
export const RECOGNITION_SCHEMA = {
  type: 'object',
  properties: {
    foods: {
      type: 'array',
      maxItems: 12,
      items: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          confidence: { type: 'number' },
        },
        required: ['name', 'confidence'],
      },
    },
    components: {
      type: 'object',
      properties: {
        protein: { type: 'string', enum: ['present', 'possibly_missing', 'uncertain'] },
        fibre: { type: 'string', enum: ['present', 'possibly_missing', 'uncertain'] },
        healthy_fat: { type: 'string', enum: ['present', 'possibly_missing', 'uncertain'] },
      },
      required: ['protein', 'fibre', 'healthy_fat'],
    },
  },
  required: ['foods', 'components'],
} as const;

/**
 * The image edit. `addition` is a name from `additions.json`, never user input.
 */
export function previewInstruction(addition: string): string {
  return `Edit this photograph of a meal by adding one realistic side serving of ${addition}.

Preserve everything else exactly: the existing food, the plate, the table, the background, the lighting, the shadows, the camera angle and the colour balance. Do not remove, replace, move or resize any food that is already present.

Place the addition beside the existing food as a normal home serving, on the same plate or in a small dish next to it, matching the photograph's lighting and perspective.

Do not add text, labels, watermarks, logos, utensils, hands, people, or decorative garnish that was not asked for. Do not change the image's aspect ratio.

Return only the edited photograph.`;
}

// ------------------------------------------------------------------- chat

/**
 * The chat model's brief.
 *
 * Deliberately narrow. The app has always refused to ship an open-ended
 * chatbot — an unbounded safety surface for a product whose whole promise is
 * "add one thing". This keeps the box conversational while the model stays a
 * describe-a-meal service: it may only name food from the app's catalogue, by
 * id, and it answers nothing else.
 */
/**
 * The picture prompt.
 *
 * Built only from catalogue names the Worker looked up itself. Nothing the
 * user typed appears here, and there is no interpolation point where it could:
 * the model hands back ids, and ids are all this function accepts.
 */
export function plateImagePrompt(foodNames: string[], additionPhrase: string): string {
  const plate = foodNames.length > 0 ? foodNames.join(', ') : 'a simple everyday meal';
  return (
    `A top-down photograph of a plate of ${plate}, with ${additionPhrase} added ` +
    `to the side. Natural daylight, plain background, appetising home cooking, ` +
    `no text, no people, no hands.`
  );
}

/**
 * The brief for writing up a plate.
 *
 * There is no user text in this one at all: the request is ids, and the prompt
 * is the catalogue names those ids resolve to. The model is writing a caption,
 * not making the decision — the rules engine on the device has already chosen
 * the addition, because that is where the dietary preferences and the
 * no-numbers rule are enforced.
 */
export const PLATE_SYSTEM = `You are the meal assistant inside a nutrition app called Plate One.

You will be told what is on someone's plate and the one thing being suggested
they add. Write at most two short, warm sentences saying what the meal is and
why that addition rounds it out.

Never mention calories, grams, macros or weight. Never say anything they are
eating is bad, wrong or unhealthy — the app only ever adds. Do not suggest a
different addition; the one you were given has already been chosen.

Leave foodIds and additionId exactly as they were given to you.`;

export const PLATE_SCHEMA = {
  type: 'object',
  properties: {
    reply: { type: 'string' },
    foodIds: { type: 'array', items: { type: 'string' } },
    additionId: { type: 'string' },
  },
  required: ['reply', 'foodIds', 'additionId'],
} as const;
