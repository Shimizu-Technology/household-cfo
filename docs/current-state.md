# Household CFO current state

Updated: 2026-07-17

This is the canonical implementation-status document for Household CFO Method. Product briefs and older PR roadmaps remain useful historical context, but this file is the source of truth for what is built, merged, locally proven, production-proven, and still conceptual.

## Product center

Mrs. Mel's intended operating rhythm is:

```text
Annual household plan
→ conversational, voice, receipt, or statement capture
→ Mia drafts and categorizes
→ the Household CFO reviews
→ Rails confirms actuals or plan changes
→ statements reconcile prior activity into the correct months
→ Mia coaches from approved numbers and patterns
```

The transaction loop and conversation loop are the core. Wealth, CFO Filter, and Optionality support the method, but they should not obscure review work, month/year position, or the next CFO move.

## Built in the current code

- Clerk/Postgres participant workspaces and cohort/admin controls.
- Annual budget years, periods, categories, allocations, confirmed actuals, and pending drafts.
- Fixed/discretionary/expected sinking-fund/unexpected sinking-fund classification.
- Text transaction capture with confirm, edit, ignore, reopen, and audit-safe actuals.
- Private S3 document imports for budgets, receipts, screenshots, statements, spreadsheets, and pay stubs.
- Receipt/statement extraction, split drafts, month assignment, matching/deduplication, and merchant/category learning.
- Private source preview, expiring download links, source deletion, and import deletion controls.
- Backend voice transcription with an editable transcript before send.
- Rails-approved Mia answer packets, model narration, and deterministic fallback.
- Supervised Mia action drafts for allocation and category changes with review-before-apply.
- Token-bounded conversation continuity and model-backed strict intent resolution.
- Effective-dated recurring income changes, zero-dollar income endings, and month-specific one-time income.
- Annual-plan look-ahead for monthly income, planned outflow, baseline surplus, upcoming spending spikes, and expected irregular-expense drivers.
- A financial cockpit on Home and Budget that separates confirmed actuals from pending review, ranks category pressure, shows Expense Stack usage, and visualizes all 12 months of income versus planned outflow.
- A pilot-first Home path that lets a basic participant save five household essentials, while keeping the existing upload-heavy path available for power users.
- An in-app mobile tester guide and structured, authenticated feedback flow with an optional private screenshot.
- A privacy-bounded pilot analytics funnel for setup, Mia, upload, draft, confirmation, failure, and review-completion signals.
- Admin/cohort progress limited to invitation, sign-in, setup state, pending-review state, and a safe last-activity timestamp.

## Locally proven

- Rails model/controller/service suite.
- Frontend lint, typecheck/build, dependency audit, and source-derived design checks.
- Authenticated local participant navigation, annual budget, pending transaction review, match suggestions, and private source preview.
- Desktop, 390-pixel mobile, and 320-pixel compact-mobile rendering of the participant shell and financial cockpit without document or money-value overflow.
- Live Mia response path through the configured model.

The financial cockpit browser coverage verifies:

- Monthly expected income, planned outflow, confirmed actuals, pending review, and remaining plan capacity.
- Pending drafts remain visually and mathematically separate from confirmed actuals until approval.
- Expense Stack and category-pressure views use the selected month's plan and activity.
- The annual cash-flow chart shows all 12 months, including scheduled income changes and spending spikes.

Rendered Playwright checks cover:

- Red/readiness guidance consistency.
- Home review-first hierarchy and month/year context.
- Dynamic readiness quick prompts.
- Bounded chat rendering and lazy attachment images.
- Mobile status-card layout, horizontal overflow, and navigation affordance.
- Basic and power-user first-session paths, tester guide, and private feedback on desktop, 390-pixel mobile, and 320-pixel compact mobile.
- Admin progress visibility without participant readiness percentages or financial details.
- Explicit confirmation boundaries for transaction and Mia budget-change drafts.
- Failed receipt upload recovery without losing the upload path.

## Pilot operating boundaries

The first cohort can use manual entry, Mia, voice, receipts, statements, general documents, annual budgets, and supervised review without Plaid. The supported first session is:

```text
Invitation and sign-in
→ save five household essentials
→ ask Mia or create one manual transaction
→ review before confirming
→ add documents only when useful
```

The alternative power-user path begins with a budget upload and then adds statements, receipts, or pay stubs through the same review-before-apply boundary. See `docs/pilot-tester-guide.md` for the participant-facing instructions and `docs/pilot-analytics-contract.md` for the event and coach-visibility privacy contract.

Pilot feedback is stored in the participant's authenticated household scope. Its narrative and optional screenshot are never copied into PostHog or shown in the cohort progress screen. Participants are warned not to include financial values, account information, document contents, passwords, or private Mia messages.

## Not yet production-proven

Do not mark these complete from unit tests or local browser checks alone:

- Phone receipt screenshot → extraction → review → confirm → actuals on the custom domain.
- Multi-month statement → correct periods → match/dedupe → month close on the custom domain.
- Real phone voice → editable transcript → pending draft only.
- Multi-turn Mia budget change → review card → apply/cancel in production.
- Private preview/download/delete authorization in production.
- Participant/admin isolation using representative production accounts.
- Real iOS Safari and Android Chrome behavior.

Record production evidence against `docs/production-readiness-checklist.md` after each deploy.

## Current readiness rule

The application currently calculates readiness deterministically from monthly cash flow, protected liquid assets, and the household's saved runway target:

- Red: the household has not yet met the Yellow conditions.
- Yellow: monthly cash flow is nonnegative and protected liquid assets cover at least half of the saved runway target.
- Green: monthly cash flow is positive and protected liquid assets cover the full saved runway target.

With the default six-month runway target, Yellow begins at three months and Green begins at six months. Home shows both dollar thresholds and remaining gaps. This is the implemented pilot rule; Mrs. Mel still needs to confirm that it is the final coaching-method definition.

Optionality uses this same approved readiness status for plain-language fit guidance rather than presenting a separate, arbitrary 0–100 score. Wealth reports the current debt balance as dollars remaining; it does not display payoff progress because the product does not yet store an original payoff baseline.

## Product decisions to confirm with Mrs. Mel

These require product approval rather than engineering inference:

- Exact Red/Yellow/Green thresholds and whether Red always means zero discretionary safe-to-spend.
- The 20–30 representative Mia questions and examples of a good versus bad response.
- Whether mobile keeps all seven tabs visible through horizontal navigation or moves secondary modules under More.
- Mia Memory: what can be remembered automatically, what requires confirmation, what a coach can see, and how participants edit, forget, or pause it.

## Next sequence

1. Deploy the bounded pilot-readiness release and complete the signed-in production smoke checklist with representative participant and admin accounts.
2. Give the mobile tester guide to the initial six participants, then use the same first-session path for the additional 10–15 participants.
3. Record production evidence for phone uploads, voice, statement matching, private document controls, supervised Mia changes, and participant/admin isolation.
4. Review the remaining readiness, Mia-quality, memory, and coach-visibility decisions with Mrs. Mel.
5. Build visible, user-controlled Mia Memory only after that discovery; keep Plaid as a separate optional validation track.
