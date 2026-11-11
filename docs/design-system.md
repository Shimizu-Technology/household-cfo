# Design system

How participant and staff screens size, space, color, and word things. Use this before adding styles so screens stay one system.

## Where styles live

App-wide stylesheets load in the order below (verified from the production CSS bundle). Component stylesheets in `web/src/components/*.css` load wherever their component is first imported, so they can appear before or after these. When two rules have equal specificity and importance, the later one wins; selector specificity and `!important` still take precedence over order, so the newer stylesheets use selectors at least as specific as the legacy rules they replace.

| Order | File | Purpose |
| --- | --- | --- |
| 1 | `web/src/styles/tokens.css` | The scale: text sizes, weights, spacing, radii, elevation, status colors. |
| 2 | `web/src/index.css` | Document defaults. |
| 3 | `web/src/App.css` | Legacy component styles, now expressed in tokens. Avoid adding new rules here. |
| 4 | `web/src/styles/shell.css` | Identity row and participant navigation (bottom tab bar on phones). |
| 5 | `web/src/styles/cards.css` | Shared card treatments: status dots, month plan summary, the serif rule, the one section-title rule, the Biba card. |
| 6 | `web/src/styles/home.css` | Home: greeting, readiness line, month at a glance. |
| 7 | `web/src/styles/mia.css` | Ask Mia surface: her monogram, chat bubbles, greeting and first-message starters. |
| 8 | `web/src/styles/charts.css` | Annual cash-flow chart (surplus and shortfall bars). |
| 9 | `web/src/dialogViewport.css` | Dialog sizing against the visible viewport. |
| 10 | `web/src/styles/opening.css` | Program, sign-in, and recovery panels. |
| — | `web/src/components/*.css` | Component-scoped styles, loaded with their components. Use tokens. |

## Tokens

- **Text:** `--text-xs` (13px, labels and captions only) · `--text-sm` (14px) · `--text-md` (16px, body and inputs) · `--text-lg` · `--text-xl` · `--text-2xl` · `--text-3xl` (fluid page titles). Nothing smaller than `--text-xs`. Inputs stay at `--text-md` so iOS does not zoom.
- **Weight:** `--weight-regular` · `--weight-medium` · `--weight-semibold` · `--weight-bold`. No 800–900.
- **Space:** `--space-1` (4px), `--space-2` (8px), `--space-3` (12px), `--space-4` (16px), `--space-5` (20px), `--space-6` (24px), `--space-8` (32px), `--space-10` (40px). There is no `--space-7` or `--space-9`.
- **Radius:** `--radius-sm` (10px) · `--radius-md` (14px) · `--radius-lg` (20px) · `--radius-pill`.
- **Elevation:** `--shadow-sm` (resting cards) · `--shadow-md` (raised panels) · `--shadow-overlay` (dialogs and sheets).
- **Status:** `--color-success`, `--color-warning`, `--color-danger` (aliases of the `--status-*` brand values).

Custom properties are not valid inside `@font-face`; use literal values there. The design regression check enforces this.

## Brand

Coach brands set colors and the display and body font families through `BrandDocument`. `BrandDocument` requests only the active brand's selected web-font families (at most one display and one body family); system font choices request nothing. The Google sign-in button loads its own Google Sans face separately. Do not hard-code brand colors; use `--emerald` (primary), `--emerald-soft`, `--gold` (accent), `--ink`, `--muted`, `--line`, `--paper`, and `--cream`.

## Serif

Mrs. Mel's prototype was editorial, and the serif is how that survives in a calm phone-first layout. The palette stays exactly as it is; the serif is the only thing brought back from the prototype's typography.

Cormorant Garamond (`--font-display`, already loaded and self-hosted) is used for exactly these:

- **Screen titles:** Home, Budget, Savings and the other `h2[data-page-heading]` titles, plus the welcome title on an empty Home.
- **Mia:** her greeting on the empty chat and the monogram "M" on her avatar.
- **One hero figure per screen:** "What's left · planned" on Home and "Set aside so far" in the savings challenge. Only a known amount gets it; "Not entered" and "No amounts added yet" stay in the text face.
- **The Biba card** headline, and Mrs. Mel's closing line in the footer.

Never use it for body text, labels, buttons, tables, forms or money columns. Every other figure stays in the text face with tabular numbers.

- **Figures:** Cormorant's default numerals are old-style (the 3, 4, 5, 7 and 9 drop below the line). Set `font-variant-numeric: tabular-nums lining-nums` on any serif figure; both features are in the shipped font file. A `font-variant-numeric` that omits `lining-nums` replaces the global default and brings the old-style numerals back.
- **Sizes:** titles are 28px or more on a phone (`clamp(1.75rem, 7vw, 2.25rem)`). The hero figure is `clamp(2.75rem, 11vw, 3.5rem)` and its two companion figures drop to 24px so one number leads.
- **Weight:** 600 for titles and figures. The footer line is 500 at `--text-lg`.

The serif rule lives in `styles/cards.css`. Do not set a different `font-family` on a heading elsewhere; if a title needs to change, change that rule.

## Mia's look

- **Monogram:** the assistant's initial in the serif, in the brand colour (`--emerald`) on `--emerald-soft`, inside a 1px ring in `--emerald`. It is the existing `.message-avatar`, so the chat header, each reply, the typing row, the daily prompt and the empty chat all share it, and another coach's assistant gets its own initial from `useBrand().assistantName`.
- **Bubbles:** a square corner on the speaker's side. Mia's bubble has a square top-left corner on `--cream` with a hairline; the participant's has a square bottom-right corner in `--emerald` with white text (7:1). The author name stays in the markup, visually hidden, for screen readers.
- **Her lines:** the empty chat opens "Håfa adai, I'm Mia." and "No judgment, no jargon. Tell me what's going on with your money." The greeting reads "Hi, I'm <name>." for any other assistant. A program can still pass its own intro line. Home's first-run panel says "Takes about 3 minutes. You can skip anything." Do not add CHamoru phrases anywhere else; her brief says no reflexive phrases.
- **Closing line:** "Not just to look wealthy on paper. The goal is to feel safe in your actual life." with "The Household CFO Method" under it, above the disclaimer. `BrandFooter` shows it only when the screen passes `closingLine` and the brand's organization name is `Household CFO Method`, so a coach workspace never inherits it and the savings program (which shows its own name) leaves it off.

## Patterns

- **Navigation:** four primary destinations plus More. On phones they sit in a bottom tab bar; never cover content with floating buttons.
- **Status:** a small colored dot beside a card label, not a colored edge.
- **Labels:** sentence case for buttons and controls. No eyebrows (small uppercase tracked labels).
- **Section titles:** one rule in `styles/cards.css`: sentence case, 16px, semibold, ink, a hairline beneath. It names the group of rows below; do not add another heading style or a container top border beside it.
- **Numbered groups:** Budget's four spending groups are numbered 1 to 4 in the order they are read, in a 28px ring in the group's colour, with the number and name carrying the meaning. It is a CSS counter on `.expense-stack-list`.
- **Milestones:** `BibaCard` is the one celebration: a serif "Biba! Day 30 is done.", one sentence with the participant's real figure, one action, a 200ms fade (none under reduced motion), no confetti and nothing that moves. Use it when the participant approves Day 30, 60 or 90.
- **Money:** tabular figures (set globally). Each number appears once per screen.
- **Empty states:** say what will appear and offer one next step.

## Words

Write for a household, not an engineer. Never show raw server or provider messages; map them to plain copy (see `web/src/lib/workspaceLoadMessage.ts`). Avoid internal terms such as request, server, scope, revision, source row, provenance, or stale. Keep money rules exact: pending is not actual, unknown is not zero, and reported is not bank-verified.
