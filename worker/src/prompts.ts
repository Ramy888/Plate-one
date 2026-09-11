/**
 * Every prompt in the Worker.
 *
 * None of them interpolate anything a user typed or said. The plate prompt is a
 * fixed template over catalogue names the Worker looked up itself, which is the
 * only version of this that survives contact with someone trying.
 */

export function plateImagePrompt(foodNames: string[], additionPhrase: string | null): string {
  const plate = foodNames.length > 0 ? foodNames.join(', ') : 'a simple everyday meal';
  // With no addition this is a picture of the meal as described, which is what
  // the plate on the voice screen shows while the conversation is still going.
  const added = additionPhrase ? `, with ${additionPhrase} added to the side` : '';
  return (
    `A top-down photograph of a plate of ${plate}${added}. ` +
    `Natural daylight, plain background, appetising home cooking, ` +
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
