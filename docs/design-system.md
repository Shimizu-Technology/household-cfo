# Design system

Household CFO uses Look A: cream ground, paper cards, plum derived from the coach’s primary, and the brand’s display serif. A participant runs their household money; Mia coaches. Keep existing words, accessible names, heading levels and financial rules when restyling a screen. Unknown is never zero, pending is never spent, and nothing financial changes without review.

## Styles and cascade

`main.tsx` loads `styles/tokens.css`, `index.css`, then `appStyles.ts`. The latter loads `App.css`, `shell.css`, `cards.css`, `home.css`, `mia.css`, `charts.css`, `motion.css`, then **`ui.css`**. New shared primitives belong in `ui.css`, not the legacy `App.css`. `opening.css` follows at entry. `dialogViewportBase.css` supplies shared entry/exit motion and viewport variables; the workspace’s `dialogViewport.css` adds keyboard-aware sizing after component styles.

Component CSS may arrive later in a lazy chunk. Shared control rules deliberately use `body :is(#root, [role='dialog'], [role='alertdialog'])` so their visual contract wins over component classes, including portals. They preserve existing component dimensions. Do not compete with them by adding a more specific screen rule. `.ui-brand` recomputes the semantic aliases for locally scoped brand previews; production `BrandDocument` writes the root variables.

## Tokens and white label

Every colour and font comes from the active `BrandDocument` brand. No Household CFO hex values in component CSS. The old names remain supported; use the honest name in new CSS.

| New name | Existing source | Use |
| --- | --- | --- |
| `--brand` | `--emerald` | Primary action, current month |
| `--brand-strong` | `--berry` | Primary hover, tonal/text action foreground |
| `--brand-soft` | `--emerald-soft` | Tonal actions and selected controls |
| `--accent-warm` | `--gold` | Spent or tight; terracotta, never decorative gold |
| `--positive` | `--status-green` | Set aside, checked in |
| `--surface-ground` | `--cream` | Page ground |
| `--surface-card` | `--paper` | Paper card and fields |
| `--rule` | 65% `--line` on paper | Dividers inside a card |

`--ink`, `--muted`, `--line`, `--brand-on-primary`, `--brand-focus`, `--font-body` and `--font-display` remain the text, edge, action-foreground, focus and type sources. Status aliases `--color-success`, `--color-warning`, `--color-danger` retain the `--status-*` contract. Status is a dot **and a word**, never colour alone.

**One answer card per screen.** Only that card uses `--brand-deep`. Its CSS fallback is `color-mix(in srgb, var(--emerald) 60%, black)`. `lib/brandDeep.ts` starts at that shade and darkens until the page-ground foreground reaches 7:1. `--on-brand-deep` is that foreground; `--on-brand-deep-muted` reaches at least 4.5:1. A dark page ground receives a readable light foreground fallback. `BrandDocument` updates and restores all three together when a brand changes. Do not author a separate plum per coach or use the deep shade for navigation, buttons, or general cards.

Data marks have two sets: `--data-spent`, `--data-planned`, `--data-remainder` on paper; `--data-deep-spent`, `--data-deep-planned`, `--data-deep-remainder` on the answer. `.ui-answer` selects its set automatically. Values stay readable as text; marks never carry meaning alone.

## Measurements and typography

- Paper cards: 1px `--line`, 20px `--radius-lg`, 18px padding. No shadows at rest. Inside a card, use rows and hairlines, never another card.
- Rows: at least 56px. Targets: at least 44×44px. Inputs: `--text-md` (16px) so iOS does not zoom.
- Text: `--text-xs` 13px labels/captions, `--text-sm` 14px, `--text-md` 16px body, then `--text-lg`, `--text-xl`, `--text-2xl`, `--text-3xl`. No text smaller than 13px.
- Body regular 400; labels medium 500 and muted; section titles 16px semibold 600; figures semibold. Do not introduce new 700 weights.
- Spacing: `--space-1/2/3/4/5/6/8/10` = 4/8/12/16/20/24/32/40px. Radii: `--radius-sm/md/lg/pill` = 10/14/20/999px.
- Elevation tokens are legacy values, not permission to add shadows. The floating phone navigation is the explicit navigation exception; its exact CSS policy entry belongs to the shell slice.

The display face (`--font-display`, Household CFO’s Cormorant Garamond) is for the wordmark, page titles, the one answer figure, assistant’s name and monogram, numbered stack circles, dialog/sheet titles, and the existing Biba headline and brand closing line. Body, labels, buttons, forms, tables and all other money columns use `--font-body`. Page titles are 32px on phones; the answer figure is at most 56px. Serif figures always declare `font-variant-numeric: tabular-nums lining-nums` **after** any `font` shorthand, which resets it. Do not use custom properties inside `@font-face` descriptors.

## Primitives

Plain classes, semantic HTML, no UI framework. Choose the element for the action: an `<a>` navigates, a `<button>` acts, a plain row displays information. Do not add button roles to decorative marks.

| Class | Use it for |
| --- | --- |
| `.ui-card` | One group on paper |
| `.ui-answer` | The screen’s answer: label, figure, caveat, at most one bar and key |
| `.ui-title` | Serif page title |
| `.ui-figure` | The one serif answer figure, only when known |
| `.ui-label` | 13px medium muted label |
| `.ui-section` | 16px semibold section title; may wrap a heading and trailing link |
| `.ui-rows` / `.ui-row` | A divided group / a row as link, button or plain information |
| `.ui-btn` | Action base, combined with `--primary`, `--tonal` or `--text` |
| `.ui-btn--full` | Full-width action; use on phones when there are one or two actions |
| `.ui-bar` / `.ui-key` | Segmented spending bar and readable values |
| `.ui-track` | One progress fill and optional goal tick |
| `.ui-cols` | Two to twelve monthly columns with readable labels |
| `.ui-chip` | A small 44px control; `aria-pressed` marks selection |
| `.ui-pill` | Noninteractive neutral status; `--good` or `--attention` plus dot and word |
| `.ui-dot` | Small data/status mark; `--good`, `--attention`, `--neutral`, `--spent`, `--planned`, `--remainder` |
| `.ui-monogram` | Assistant’s initial, sourced from the active assistant’s name |
| `.ui-field` | Text input or textarea with the shared field look |
| `.ui-select` | Optional semantic class on a native select; all selects are styled |
| `.ui-check` | Label wrapping a checkbox/radio, with a 44px hit area and 22px drawn mark |
| `.ui-disclosure` | Native details/summary, shared chevron and inner hairline |

Modifier names are complete classes: `.ui-btn--primary`, `.ui-pill--good`, etc. Rows use `.ui-row__body` containing `.ui-row__title` and `.ui-row__detail`, with optional `.ui-row__trailing` and an `aria-hidden` `.ui-row__chevron`. Let long detail wrap at narrow widths; do not truncate financial meaning. Answer notes use `.ui-answer__note`.

One primary action per card or row. Legacy `.button`, `.button--primary`, `.primary-button`, `.secondary-button`, `.danger-button`, `.text-button` now share the same three looks while retaining their dimensions. Danger remains a tonal caution. Disabled controls keep the enabled shape and lower contrast. For links, `aria-disabled` is only a visual/semantic state: the caller must prevent navigation when disabled.

## Charts driven by data

Keep the figure and its meaning as text. Hide decorative bars from assistive technology with `aria-hidden="true"`, then supply exact values in the key and one plain sentence beneath. A chart without a visible key must have a labelled list or table of its numbers. Unknown amounts omit their segment and say “Not known yet”; never turn them into zero. No chart library.

```tsx
<div className="ui-bar" aria-hidden="true"
  style={{ '--spent': '26%', '--planned': '39%' } as CSSProperties}>
  <span className="ui-bar__spent" />
  <span className="ui-bar__planned" />
  <span className="ui-bar__remainder" />
</div>
<div className="ui-key"><span>Spent<strong>$1,612</strong></span>{/* remaining exact values */}</div>
<p>Confirmed purchases use 26% of this month’s income.</p>
```

Compute valid nonnegative segment percentages from the screen’s data; clamp at the source so their sum never exceeds 100%. Segment widths use the parent custom properties shown above. `.ui-track__fill` uses `--value: 42%` (or `width`); optional `.ui-track__goal` uses `--goal: 100%`. Both are clamped by CSS. Columns use `--columns: 2` through `12`; each `.ui-cols__column` has a `.ui-cols__bar` with `--value` and a `.ui-cols__label`. Mark the current column with `.ui-cols__column--current`, a tight column with `--attention`, and expose those words in its accessible label along with the full month and amount. Use one brand hue plus neutrals; warm accent is reserved for a tight value. Bars do not animate on data changes or tab switches. A screen may opt into one first-reveal fill using transform, with movement removed under reduced motion.

## Controls, motion and phone web

Selects use one `--select-chevron` SVG derived from the resolved muted brand text (SVG images cannot inherit HTML `currentColor`), native picker and 44px field shape. Number inputs have no spinners; date inputs retain their native picker. Checkboxes/radios use 22px marks inside 44px targets and restore native appearance under forced colours. Details keep native keyboard/expanded semantics and one rotating chevron. One focus ring: 2px `--brand-focus`, 2px offset, including portals and focused notices. Noninteractive route headings retain their intentional outline exemption.

Colour and background: `--duration-color: 150ms`, `ease`. Entrances: `--duration-enter: 220ms`, `--ease-out` (or `--ease-drawer` for sheets). Exits: `--duration-exit: 150ms`, faster than entrances. Press: `scale(0.97)`, `--duration-press: 120ms`, `--ease-out`. Spinner: about 600ms. No animation on tab switches or other frequent actions. Hover only inside `@media (hover: hover) and (pointer: fine)`.

Shared React panels use `@starting-style` entrances. `usePilotDialog` returns `{ dialogRef, requestClose }`; dismissal buttons/backdrops and Escape call the current close callback synchronously, committing unmount and releasing reads, focus and scroll ownership immediately. A guarded callback may keep the panel open; it never starts an exit. Successful financial actions remain synchronous.

`dialogExit(panel, closeCallback)` captures a non-private surface before closing, then animates only an inert, `aria-hidden`, pointer-transparent DOM copy after the original is removed. It has no React handlers, IDs, form associations or focus ownership. Typed values, selection, checks and child scroll positions survive in the copy. The opacity/transform animation lasts 150ms, with a 200ms removal deadline. Reduced motion fades without movement. Private record panels must carry `data-dialog-private`; private panels, media/file/password content, native dialogs, unsupported browsers and CSS-free tests close without a copy. Private files, evidence, history and sign-in content must never outlive dismissal as pixels. There is no `onDismiss` callback: normal owner cleanup is the lifecycle boundary. Native owners close synchronously; CSS may retain their native backdrop transition, never delay their React cleanup. The More sheet stays with the shell’s lifecycle.

Interactive elements use `touch-action: manipulation` and no tap highlight; button/nav labels do not select. Content stays selectable. Selection and caret use brand colours; headings balance. Honour safe-area insets and retain zoom. Desktop emulation cannot establish real-phone keyboard, gesture, installed-PWA or safe-area behavior.

## Responsive navigation and layout

For **new code**: phone up to 620px; tablet 621–1023px; laptop 1024px and up. CSS custom properties cannot be used as media-query breakpoints. Existing screens may retain older breakpoints until their slice.

The phone tab bar may float as a paper pill. Content must clear its entire height, gap and safe-area inset. Chat keeps navigation in flow beneath the composer. Tablet keeps the top navigation row; laptop receives a sidebar in the shell slice. This foundation does not restructure any screen or build that navigation.

## Preview and verification

In opted-in development/test only, open `/ui-foundation-qa.html` with `VITE_E2E_AUTH=true`. It shows every primitive in Household CFO and a blue coach with different fonts, plus controls, disabled states, and a native dialog. It is a separate HTML entry, absent from the production build and routing. `e2e/ui-foundation.spec.ts` checks overflow, target sizes, contrast, keyboard behavior, forced colours and dialog dismissal across the browser matrix. The chosen-look references and six existing screen comparisons remain the visual acceptance, beyond test counts.

## Words and privacy

Write for a household, not an engineer. Keep approved visible copy when restyling. Never show raw provider/server messages, IDs or internal platform names. Sharing starts private; coaches and sponsors see financial information only through grants. Sponsor reports remain coarse, with a minimum group of five. Never change the sealed persona configuration to adjust visual design.
