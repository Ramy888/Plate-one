# The Plate One API

A Cloudflare Worker. It holds every key, enforces allowances a patched client
cannot lie its way past, and proxies the calls that cost money. **It stores no
photographs and no meal data** — what anyone ate stays on their own device.

There are no accounts. A device gets an anonymous id on first use, that id
carries a daily allowance, and the deployment as a whole carries a hard ceiling
on top of it.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | Liveness, and how much of today's budget is left |
| `POST` | `/v1/device` | Register an anonymous device, return a token and allowance |
| `DELETE` | `/v1/device` | Forget the device, its allowance, events and reports |
| `GET` | `/v1/quota` | Current allowance, without spending any |
| `GET` | `/v1/preview/{id}.jpg` | Serve a generated plate |
| `POST` | `/v1/plate` | Write up and draw a plate. Ids in, never words. Addition optional |
| `POST` | `/v1/plate/keep` | End the free try. The plate itself stays on the device |
| `POST` | `/v1/voice/token` | Mint a single-use AssemblyAI Voice Agent token |
| `POST` | `/v1/promo` | Redeem a code for more conversations |
| `POST` | `/v1/report` | Report an AI result |

## Design decisions

**Everything is free, and the budget is protected by arithmetic instead.**
There is no paid tier and nothing to sign into: a judge, or anyone else, opens
the URL and talks. Two limits stand behind that.

| | Free tries | Pictures | Conversations | Window |
|---|---|---|---|---|
| Per device | 1 | 10 | 30 | per day |
| Whole deployment | `GLOBAL_CALLS_PER_DAY` (2000), across all of it | | | per day |

One try draws the meal a few times over as it is described, and again for each
suggestion tried, which is why pictures outnumber tries by ten.

The per-device allowance stops one phone running up a bill. It does nothing
about a hundred phones, or one script rotating device ids — which is exactly
what a public demo URL invites. `src/budget.ts` is the second limit, and it is
the thing standing between that URL and an empty API account. Every route that
costs money spends one unit of it **before** it spends the caller's own
allowance, so a device is never debited by a service that was never going to
answer. When it is reached, the app says so in plain words and falls back to
the offline path.

`worker/test/plate.test.ts` drains it and asserts the route returns 429.
Deleting the check makes that test fail; that is the only reason to believe it
works.

**Allowances live in Durable Objects.** Spending is a read-modify-write; in D1
two requests can both read "1 left" and both spend it. A Durable Object is
single-threaded per id, so the race cannot occur — no transactions, no
optimistic retries. `QUOTA` has one instance per device; `GLOBAL_CAP` has
exactly one, for everybody.

**One free plate a day, and keeping it is what spends it.**

A try is the whole journey: talk, be recommended something, watch it drawn.
Trying all three suggestions costs nothing — it is one try either way — and
`POST /v1/plate/keep` is the door at the end of the corridor. Drawing is
refused once the try is over, because there is nothing left to do with the
picture.

AssemblyAI is free for this event, so talking has no door on it at all. A drawn
plate is a Gemini call and a Workers AI image, which is real money, and that is
what the counter is for.

**Promo codes live in a secret, never in this repository.** It is public and
MIT licensed: a list of codes in the client, a migration or a seed file is a
list of free credits for everyone who reads it. Hashes would not help either —
a code this short has few enough possibilities to walk through, which is also
why `/v1/promo` has a tight per-IP ceiling and a test that drains it.

`PROMO_CODES` is `CODE:grants` pairs. A code grants that many more tries, the
conversations to have them in, and ten times as many pictures — a code that
granted only tries would run out of pictures inside the first one. What it
grants survives the daily reset: a code handed out in the evening that expires
at midnight is barely a code.

Redemptions are recorded per device, and a code's total use is capped by
`PROMO_USES_PER_CODE`. The primary key on `(code_hash, redeemer)` is what
actually enforces the first of those; the check in front of it only turns a
constraint violation into a sentence.

**The API key never reaches the client.****The API key never reaches the client.** A browser cannot set an
`Authorization` header on a WebSocket, so `/v1/voice/token` mints a single-use
AssemblyAI token and the client opens `wss://agents.assemblyai.com/v1/ws?token=…`
with that. The audio never comes here — it goes straight from the browser to
AssemblyAI, which is one less hop of latency and one less place a recording of
someone's dinner could be sitting.

Note the Bearer prefix on the upstream call. The Voice Agent API requires one;
AssemblyAI's other products take the raw key. Getting it wrong fails at connect
time, far from the cause, so there is a test pinning it.

Tokens are short-lived (120 s to redeem) and the session is capped at 10 minutes.
AssemblyAI's own default cap is three hours, which is three hours of billing for
a tab someone left open.

**The same plate is only drawn once.** A picture is stored under a key derived
from the sorted food ids and the addition, so asking for the same plate again
is a lookup — no model, no wait, no allowance spent. This is what makes the
voice screen affordable: the meal is redrawn as the conversation fills it in,
and someone flipping between three suggestions would otherwise pay for the same
picture every time they flipped back. `worker/test/plate.test.ts` proves it by
registering exactly one image stub and asking twice.

Sorting matters: "rice and chicken" and "chicken and rice" are one meal.

**An addition is optional.** `/v1/plate` with no `additionId` draws the meal
alone, which is what the plate shows while the conversation is still going. The
id is still checked when one is sent — that check is what keeps free text away
from the image model, and it did not become optional.

**A refused model call is refunded.** If Gemini or AssemblyAI errors after the
allowance was taken, the unit goes back. The user should not pay for our failure.

**No free text ever reaches the image model.** `/v1/plate` accepts catalogue ids
and nothing else. The Worker resolves them against a generated closed set, and
the picture prompt is a fixed template over the names it found. There is no
interpolation point where a spoken sentence could reach the image model, which
is the only version of this that survives contact with someone trying.

**An AI failure is never a dead end.** Every error path leaves the user able to
build the meal by hand — that path has no network, no allowance and no model in
it, and it always works.

**The app's own page is on a different origin, so CORS is not optional.**
`ALLOWED_ORIGINS` is a comma-separated allowlist, and a browser origin missing
from it fails every call before it is sent — the app looks offline and this
Worker's log stays empty, which is a miserable thing to debug. It is an
allowlist rather than `*` for cost, not for secrecy: CORS does not protect the
device token, but any page allowed here can spend this deployment's budget
through its own visitors' browsers.

Two things to remember:

- **The deployed page's URL has to be added before it will work.** The default
  is a placeholder.
- `flutter run -d chrome` picks a random port, which will not be on the list.
  Pass `--web-port 8080` and build against `PLATEONE_API=http://localhost:8787`.

## Configuration

Vars live in `wrangler.jsonc`. Secrets are set with `wrangler secret put`:

| Secret | Without it |
|---|---|
| `ASSEMBLYAI_API_KEY` | `/v1/voice/token` returns `voice_unconfigured`, and `/health` says so |
| `GEMINI_API_KEY` | `/v1/plate` returns a picture with no caption |
| `PROMO_CODES` | `/v1/promo` refuses every code |

The test run does **not** need either: `vitest.config.ts` binds deliberately fake
values, so a contributor with no keys still gets a green suite — and the
assertion that the key never reaches the client is checked against a value the
test controls rather than one that might be empty.

`GLOBAL_CALLS_PER_DAY` is the number to change before sharing the URL widely.

## Running it

```bash
npx wrangler d1 create plateone          # paste the id into wrangler.jsonc
npx wrangler r2 bucket create plateone-previews
cp ../.env.example .dev.vars             # then fill it in
npm run migrate:local
npm run dev
npx vitest run                           # 76 tests
```

The R2 bucket wants a lifecycle rule deleting anything under `p/` after 24
hours, so expiry is enforced by infrastructure rather than by remembering to
call delete.

Workers AI has no local simulator, so the `AI` binding is marked remote:
`wrangler dev` calls the real thing, which costs real money in local dev too.
The tests mock it.

## Known limits

- **The picture is decoration.** If image generation fails, the words still come
  back. This is deliberate and tested.
- **`/health` reports the budget honestly**, including when it is exhausted. A
  deployment that has spent its day should look spent, not healthy.
