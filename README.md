# Plate One

**Tell it what is on your plate. It names the one thing to add.**

Plate One is a voice agent for the smallest useful nutrition question: what
would make this meal more satisfying? Not what to cut out, not how many calories
are in it, not what you should have eaten instead. You say what you are eating,
it asks whatever it still needs to know, and it names one practical addition — a
boiled egg, a scoop of hummus, a side salad — and tells you why.

Built on the **AssemblyAI Voice Agent API** for the lablab.ai Voice Agent
Hackathon.

---

## The idea worth stealing

**The model runs the conversation. It does not make the recommendation.**

The AssemblyAI Voice Agent API delivers tool calls to the client over the same
WebSocket that carries the audio: the server emits `tool.call`, the client
answers `tool.result`. So the recommendation engine — 300 lines of pure,
deterministic Dart with no I/O — is registered as the agent's tools and runs
in the app, unchanged.

The model decides *when* to ask a clarifying question, *what* to say and *how* to
say it. It never decides what to recommend. That is what makes the answer
reproducible: the same plate always gives the same suggestion, every time, and
you can read the rule that produced it.

It also means the interesting failure mode is missing, by construction. A
language model asked to give nutrition advice will invent some — confidently,
fluently, differently each time. This one cannot: the only additions it can
name are the ones the engine returned.

## How it works

1. Say what is on the plate. Rough is fine — "rice and some chicken".
2. The agent resolves what it heard against a closed catalogue of 51 foods, and
   asks about anything it could not place rather than quietly dropping it.
3. The engine works out which of protein, fibre or healthy fat the meal is
   light on, and returns three additions that close the gap: the **fastest**,
   the **cheapest** and a **plant-based** one.
4. The agent reads one out and says why. You can argue with it.

If the room is too loud, tapping the meal and picking the food does the same
thing with no microphone and no network.

## Architecture

```
lib/
  domain/
    models.dart        Nutrients, meal slots, goals, preferences, saved patches
    patch_engine.dart  The recommendation engine — pure, deterministic Dart
    food_matcher.dart  Spoken food names onto catalogue ids
  data/
    catalog.dart          Loads the bundled JSON food catalogue
    prefs_repository.dart On-device persistence (shared_preferences)
    scan_api.dart         The Worker client
  state/providers.dart  Riverpod wiring
  ui/                   The screens and the shared widgets
assets/data/
  foods.json            51 foods
  additions.json        31 additions

worker/                 Cloudflare Worker — holds every key
  src/
    budget.ts           The deployment-wide daily cap
    quota.ts            Per-device allowance and the global cap, as Durable Objects
    scan.ts             Photo -> Gemini -> confirmed food names
    plate.ts            A written-up, drawn plate. Ids in, never words
    device.ts           Anonymous device identity
```

The whole recommendation is a pure function of `(meal slot, foods, goal,
preferences, recent history)`. That is what makes it testable, and what makes a
demo reproducible.

### No accounts, no paid tier, no gate

There is nothing to sign into and nothing to buy. Open the URL and talk. What
protects the API budget instead is arithmetic: each anonymous device gets a
daily allowance, and the deployment as a whole has a hard daily ceiling on top
of it (`GLOBAL_CALLS_PER_DAY`). When the ceiling is reached the app says so in
plain words and falls back to the offline path, which never touches a Worker.

**No key ever ships to the client.** The Worker holds them and hands out
short-lived access; `worker/src/budget.ts` is the thing standing between a
public demo URL and an empty API account, and it has a test that drains it.

**No user text ever reaches the image model.** The language model may only reply
with ids from the app's own closed catalogue; the Worker resolves those ids to
names against a generated list, and the picture prompt is a fixed template over
the names it found.

### The engine, briefly

Foods and additions carry coarse 0–3 scores for protein, fibre and healthy fat.
A plate below the threshold for a nutrient has a **gap**. Gaps are ranked by
severity, weighted by the user's goal and nudged by their recent after-meal
checks. Candidate additions are filtered by meal slot and dietary preferences,
then scored on how much of the ranked gaps they actually close — contribution
beyond what a gap needs counts for nothing, so a protein bomb never wins a fibre
gap. The most constrained angle (plant-based) picks first, so a thin candidate
list never leaves that card empty or mislabelled.

## Running it

```bash
flutter pub get
flutter run -d chrome     # or a device
```

The app is fully usable with no Worker at all: tapping foods and getting an
answer needs no network, no account and no key.

For the parts that do:

```bash
cd worker
cp ../.env.example .dev.vars   # then fill it in
npx wrangler d1 create plateone          # paste the id into wrangler.jsonc
npx wrangler r2 bucket create plateone-previews
npm run migrate:local
npm run dev
```

## Tests

```bash
flutter test                  # 194 tests
cd worker && npx vitest run   # 65 tests
```

Four layers:

- **`patch_engine_test.dart`** — the rules, on a hand-built catalogue where each
  test controls one variable.
- **`catalog_data_test.dart`** — the JSON that actually ships. Every meal slot ×
  goal combination must yield three distinct cards, and all 16 preference
  combinations × 3 slots must yield at least one honest suggestion. A catalogue
  edit that dead-ends a vegetarian, dairy-free, gluten-free, low-cost user fails
  here rather than in front of someone.
- **`app_flow_test.dart`** — the real screens, driven end to end against the real
  catalogue.
- **`worker/test/`** — the Worker against a real D1 and real Durable Objects via
  `@cloudflare/vitest-pool-workers`: the allowance arithmetic, the global cap
  refusing a paid route once the budget is gone, and the injection defence.

## Design

Tokens, components and a paste-ready prompt for every screen are in
[`DESIGN_SYSTEM.md`](DESIGN_SYSTEM.md). `lib/ui/theme.dart` remains the source
of truth.

## Deliberate omissions

No barcodes, no recipes, no cloud sync, no meal-plan generation, no streaks, no
notifications, no calorie counting, no weighing, no food diary. Each of those
would make Plate One a different, worse app.

## Licence

MIT. See [LICENSE](LICENSE).
