# Household CFO current state

Updated: 2026-07-11

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

## Built and merged through PR #32

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

## Locally proven

- Rails model/controller/service suite.
- Frontend lint, typecheck/build, dependency audit, and source-derived design checks.
- Authenticated local participant navigation, annual budget, pending transaction review, match suggestions, and private source preview.
- Desktop and 390-pixel mobile rendering of the participant shell.
- Live Mia response path through the configured model.

The pilot-hardening branch adds rendered Playwright checks for:

- Red/readiness guidance consistency.
- Home review-first hierarchy and month/year context.
- Dynamic readiness quick prompts.
- Bounded chat rendering and lazy attachment images.
- Mobile status-card layout, horizontal overflow, and navigation affordance.

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

## Product decisions to confirm with Mrs. Mel

These require product approval rather than engineering inference:

- Exact Red/Yellow/Green thresholds and whether Red always means zero discretionary safe-to-spend.
- The 20–30 representative Mia questions and examples of a good versus bad response.
- Whether mobile keeps all seven tabs visible through horizontal navigation or moves secondary modules under More.
- Mia Memory: what can be remembered automatically, what requires confirmation, what a coach can see, and how participants edit, forget, or pause it.

## Next sequence

1. Merge pilot-hardening truth, Home hierarchy, mobile, performance, and browser-test changes.
2. Deploy and complete the signed-in production smoke checklist with demo-safe fixtures.
3. Review the evidence and the remaining product decisions with Mrs. Mel.
4. Build visible, user-controlled Mia Memory only after that discovery.
5. Continue frontend screen extraction as each area is changed; do not return to adding all behavior in `App.tsx`.
