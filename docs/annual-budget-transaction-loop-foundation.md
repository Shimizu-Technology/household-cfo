# Annual budget and transaction loop foundation

> Historical implementation snapshot. Receipt/statement extraction, matching, merchant learning, and supervised Mia actions described here as future work have since merged. See `docs/current-state.md`.

This PR adds the first persisted foundation for the Household CFO annual budget loop.

## What exists now

- A household has one `BudgetYear` per year and 12 `BudgetPeriod` month records.
- `BudgetCategory` records map household-language categories to the Expense Stack:
  - `non_discretionary`
  - `discretionary`
  - `sinking_expected`
  - `sinking_unexpected`
- `BudgetAllocation` stores planned dollars per category per month.
- `TransactionDraft` stores review-before-apply transaction suggestions from chat or future imports.
- `HouseholdTransaction` and `TransactionSplit` store confirmed month-to-date actuals.

## Guardrails

- Mia can draft a transaction from chat, but the participant must confirm it before actuals change.
- Mia answers budget/report questions through the Response Contract v1: answer directly, name the data basis, keep planned budget separate from confirmed actuals and pending drafts, and admit when approved data is missing.
- Mia keeps compacted conversation continuity on the server so follow-up questions can use the active/open topic across long chats, tomorrow pickup, and same-user device changes without treating chat memory as financial truth.
- Drafts are created from simple spending language only; this is not statement reconciliation yet.
- Confirmed transactions update budget actuals through `TransactionSplit` rows.
- Drafts confirmed exactly as proposed end as `confirmed`; drafts confirmed after user edits end as `corrected` with the confirmed transaction attached for audit.
- Budget categories are archived/restored instead of hard deleted; categories with pending drafts must be confirmed, corrected, or ignored before archiving.
- Categories with confirmed transaction history can be archived; historical actuals stay visible and marked archived instead of disappearing from reports.
- Budget planning is editable only in authenticated real workspaces.
- The annual plan bootstraps from approved setup/imported expense items, not raw documents.

## API surface

- `GET /api/v1/workspace` includes `budget.annual_plan` for real workspaces.
- `POST /api/v1/budget_categories` creates a custom category and seeds all 12 monthly allocations.
- `PATCH /api/v1/budget_allocations/:id` updates one monthly allocation.
- `POST /api/v1/mia/messages` may return a `transaction_draft` when chat contains clear spending language.
- `POST /api/v1/transaction_drafts/:id/confirm` posts a confirmed transaction and refreshes workspace data.
- `POST /api/v1/transaction_drafts/:id/ignore` dismisses a draft without changing actuals.

## Next layer

The post-merge roadmap lives in `docs/post-pr20-roadmap.md`.

The next PR can build on this with receipt/photo upload from chat, bank/card statement transaction extraction, merchant/category rules, duplicate detection, split editing, and end-of-month reconciliation.
