# Plate One design system

The visual reference — rendered swatches, live components, and a paste-ready
prompt for every screen — is published here:

**https://claude.ai/code/artifact/57fe0906-0654-4305-94c6-9955588591f1**

This file is the text mirror for tooling. **If this and the code disagree, the
code wins** — `lib/ui/theme.dart` and `lib/ui/widgets/common.dart` are the
source of truth.

---

## Principles

1. **Only ever add.** Nothing implies the user's food is wrong. No red, no
   warning iconography, no "too much" language.
2. **No numbers people can fail at.** No calories, grams, macros or weights,
   anywhere. Portions are objects: "half a cup", "what fits in a cupped palm".
   Enforced by a test over the shipped catalogue and copy.
3. **One decision per screen.** One question, one primary action. Two primary
   buttons means it is two screens.
4. **Warm, not clinical.** A friend passing you something across the table, not
   a health dashboard.

## Colour

Ported from the "Organic" design system the store assets were drawn in. The app
is light-only by design; these are fixed product values, not themed.

Two hues carry everything. **Sage is the product's voice** — every primary
action and every selected state. **Terracotta is reserved**: it means Pro, or it
means "check this, it might be wrong". Spending it anywhere else makes both
meanings quieter.

| Token | Hex | Used for |
|---|---|---|
| `cream` | `#F5EAD8` | Every scaffold and app bar — the ground |
| `card` | `#EBDDC5` | Anything lifted off the ground |
| `ink` | `#201E1D` | Headings and body |
| `inkSoft` | `#645C50` | Secondary text, captions — a warm grey, not a true one |
| `line` | `16% ink` | Dividers and outlined buttons; translucent so it sits on either ground |
| `green` | `#56633F` | Primary buttons, selected borders, links |
| `greenSel` | `#CCDBB2` | The fill of a selected card, chip or tile |
| `greenSoft` | `#E1EECC` | Passive highlights, plant-based tag |
| `greenPress` | `#3D472B` | Pressed states |
| `pro` | `#8C491A` | Pro text and the destructive action |
| `proSoft` | `#FFE1D0` | Pro cards |
| `warn` | `#B2622D` | "Fastest" tag text, unmatched-food accent |
| `warnSoft` | `#FFF2EB` | "Fastest" tag ground, unmatched-food card |
| `neutral100–900` | `#F9F4ED`–`#2E2B25` | Insets, ticks, the "Cheapest" tag, toasts |
| `camera` | `#12110F` | The camera ground — near-black, still warm |

**There is no error red**, deliberately. Failures are information on a standard
card.

## Type

**Caprasimo** for display, **Figtree** for everything else. Both bundled as
static TTFs under `assets/fonts/` rather than fetched, so the first launch and
an offline launch render identically. Both are OFL; the licences ship beside
them.

Caprasimo has exactly one weight. Asking for `w700` anywhere makes Flutter
synthesise a bold and smear the face — every display style pins `w400`.

Figtree upstream is a variable font only, so the three weights here are real
static instances cut with `fonttools varLib.instancer`.

| Role | Face | Size / line / weight | Used for |
|---|---|---|---|
| `displaySmall` | Caprasimo | 30 / 1.1 / 400 | Onboarding and paywall headlines |
| `headlineMedium` | Caprasimo | 25 / 1.15 / 400 | Screen headlines |
| `titleLarge` | Caprasimo | 19 / 1.2 / 400 | Addition name, section heads |
| app bar title | Caprasimo | 17 / 1.2 / 400 | Every app bar |
| `titleMedium` | Figtree | 16 / 1.35 / 600 | Row titles |
| `bodyLarge` | Figtree | 15.5 / 1.5 / 400 | Portion guidance, policy text |
| `bodyMedium` | Figtree | 14 / 1.45 / 400 (inkSoft) | Subtitles, reasons, captions |
| `labelLarge` | Figtree | 16 / 700 / +0.16 | Buttons |

## Space and shape

`xs 4 · sm 8 · md 16 · lg 24 · xl 32 · xxl 48`. Anything off this scale is a bug.

| | |
|---|---|
| Card / sheet radius | `32` (`kRadius`) |
| Inset / tile / field radius | `28` (`kRadiusSmall`) |
| Pill radius | `999` (`kPill`) — buttons, chips and tags are fully round |
| Button height | `54`, full width, one filled button per screen |
| Card border | `2px`, **transparent** unless selected — so selecting one changes colour without moving anything |
| Screen padding | `24` horizontal |
| Elevation | `0` — colour separates things, not shadows |

## Components

`PlateCard` · `ChoiceRow` · `Pill` · `FoodTile` · `SlotChip` · filled/outlined
buttons · `PatchCard` · `EmptyState`. All in `lib/ui/widgets/common.dart` except
`PatchCard` (private to `result_screen.dart`) and the tiles (private to
`meal_screen.dart`).

`ChoiceRow` takes `showIndicator: false` where a tap acts immediately — a
chevron replaces the circle, so it never implies a confirm step that isn't there.

## Screens

Fourteen screens and one sheet. Screens 5–7 are the AI scan flow; 14 is the
same answer reached by typing instead of photographing.

| # | Screen | File | Status |
|---|---|---|---|
| 1 | Welcome | `onboarding_screen.dart` | Built |
| 2 | Goal | `onboarding_screen.dart` | Built |
| 3 | Preferences | `onboarding_screen.dart` | Built |
| 4 | Meal picker | `meal_screen.dart` | Built |
| 5 | Scan camera | `scan_camera_screen.dart` | Built |
| 6 | Confirm what it saw | `scan_confirm_screen.dart` | Built |
| 7 | Preview my patch | `preview_screen.dart` | Built |
| 8 | Your patch — the answer, drawn | `result_screen.dart` | Built |
| 9 | After-meal check | `check_screen.dart` | Built |
| 10 | Saved patches | `saved_screen.dart` | Built |
| 11 | Paywall | `paywall_screen.dart` | Built |
| 12 | Privacy & terms | `legal_screen.dart` | Built |
| 13 | Settings | `settings_screen.dart` | Built |
| 14 | Describe your meal | `chat_screen.dart` | Built |
| 15 | Say your meal | `voice_screen.dart` | Built |
| S | Report this result | `widgets/report_sheet.dart` | Built |

## Deliberately not built

**Camera scanning and Settings were once on this list and are now built.** What
genuinely stayed out:

| Dropped | Why |
|---|---|
| Register, forgot password, profile, account settings | There is one sign-in — Google, asked for at the first AI generation and nowhere else. No password to forget, no profile to edit, and no launch gate. Everything that is not an AI call runs signed out on a device token that identifies a quota, not a person. |
| Streaks, badges, daily goals | A game layer turns a nudge into an obligation — the failure mode the product exists to avoid. |
| Barcodes, recipes, meal plans | Each answers a different question than "what could I add to this?" |
| An open-ended chatbot | Still out. There **is** a chat box now, but it is a describe-a-meal service, not an assistant: the model is scope-locked to naming food, may only answer with catalogue ids, and refuses anything else. What was rejected — a box that will talk about anything — is still rejected. |

## Store assets

Full specs and the screenshot running order are in the artifact. Summary:

| Asset | Spec | Source | State |
|---|---|---|---|
| App icon | 512×512 PNG, no alpha, no rounded corners | `assets/icon/icon.png` | Ready |
| Feature graphic | 1024×500, no alpha | `assets/icon/feature_graphic.png` | Ready |
| Phone screenshots | 2–8, each edge 320–3840px | `./tool/capture_screens.sh` | **Needs re-run — the scan flow is new** |
| Promo video | Public YouTube, <2 min | — | Not made |

```bash
./tool/render_icon.sh              # icon, adaptive layers, feature graphic, launcher sizes
flutter build apk --release
./tool/capture_screens.sh          # screenshots from a running emulator
```

The mark lives in `tool/icon/` as SVG with the design tokens resolved to hex,
and `render_icon.sh` overwrites `assets/icon/`. Edit the former, never the
latter.

The screenshots rendered in the Claude Design project are **renders of the
design, not of the app** — they show icon-set glyphs and food photography the
app does not have. Capture the store screenshots from a real device. The icon
and feature graphic from that project are fine to use: the mark is identical.

## Voice

| Never | Instead |
|---|---|
| calories, kcal, macros, grams, weigh | "half a cup", "what fits in a cupped palm" |
| "You should…", "Avoid…", "Cut down on…" | "Add…", "Swap in…", "Stir through…" |
| "bad", "unhealthy", "cheat", "treat" | Name the food. No adjective. |
| "Oops! Something went wrong 😬" | "The store could not be reached. Check your connection and try again." |
| Streaks, badges, daily goals | Nothing. There is no game layer. |
| "Powered by AI", "Smart", "Intelligent" | Say what it did: "Plate One thinks it sees this." |
| Presenting a recognition as fact | "thinks it sees", "Not very sure about this one." |
| Hiding that a preview is generated | "AI visual preview — appearance and serving size are illustrative." Always visible, never dismissible. |
| Letting an AI failure be a dead end | Every error ends with "…or build the meal by hand." |

Recurring shapes: suggestions lead with an imperative verb; portions name an
everyday object then reassure; reasons state facts (`Covers protein and fibre.`);
headlines say *looks* light, not *is* light — the app is guessing and should
sound like it.
