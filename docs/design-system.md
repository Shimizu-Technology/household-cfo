# Design system

How participant and staff screens size, space, color, and word things. Use this before adding styles so screens stay one system.

## Where styles live

Stylesheets load in this order. When two rules have equal specificity and importance, the later file wins; selector specificity and `!important` still take precedence over order, so the newer stylesheets use selectors at least as specific as the legacy rules they replace.

| File | Purpose |
| --- | --- |
| `web/src/styles/tokens.css` | The scale: text sizes, weights, spacing, radii, elevation, status colors. Loaded first from `main.tsx`. |
| `web/src/index.css`, `web/src/App.css` | Legacy component styles, now expressed in tokens. Avoid adding new rules here. |
| `web/src/styles/shell.css` | Identity row and participant navigation (bottom tab bar on phones). |
| `web/src/styles/cards.css` | Shared card treatments: status dots, month plan summary, section labels. |
| `web/src/styles/home.css` | Home: greeting, readiness line, month at a glance. |
| `web/src/styles/mia.css` | Ask Mia surface and first-message starters. |
| `web/src/styles/charts.css` | Annual cash-flow chart (surplus and shortfall bars). |
| `web/src/styles/opening.css` | Program, sign-in, and recovery panels. |
| `web/src/components/*.css` | Component-scoped styles. Use tokens. |

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

## Patterns

- **Navigation:** four primary destinations plus More. On phones they sit in a bottom tab bar; never cover content with floating buttons.
- **Status:** a small colored dot beside a card label, not a colored edge.
- **Labels:** sentence case for buttons and controls. Section eyebrows may be uppercase with `0.06em` tracking.
- **Money:** tabular figures (set globally). Each number appears once per screen.
- **Empty states:** say what will appear and offer one next step.

## Words

Write for a household, not an engineer. Never show raw server or provider messages; map them to plain copy (see `web/src/lib/workspaceLoadMessage.ts`). Avoid internal terms such as request, server, scope, revision, source row, provenance, or stale. Keep money rules exact: pending is not actual, unknown is not zero, and reported is not bank-verified.
