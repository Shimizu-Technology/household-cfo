# Household CFO real-mode build plan

Updated: 2026-06-21

## Why this exists

PR #6 moved Household CFO from a static-feeling preview into a polished authenticated app shell with Clerk, PostgreSQL, mobile-first screens, Ask Mia chat, PWA assets, and OpenRouter-backed coaching. The next step is to make the app usable with each participant's own financial numbers instead of hardcoded demo data.

This document captures where the project is, Mrs. Mel's latest feedback, the product direction, and the recommended build plan for turning the preview into a real cohort MVP.

## Current status

The app currently has:

- React/Vite frontend with mobile-first Household CFO screens:
  - Home
  - Ask Mia
  - My Profile
  - Budget
  - Wealth
  - CFO Filter
  - Optionality
- Rails API backend.
- PostgreSQL configured.
- Clerk-backed invite-only auth foundation.
- Local `users` table with roles: `admin`, `coach`, `participant`.
- OpenRouter-backed Mia endpoint with deterministic fallback.
- PWA manifest, icons, and service worker.
- Demo-safe API endpoints under `/api/demo/*`.
- Demo-safe static household data in `Demo::HouseholdData`.
- Mia localStorage chat persistence scoped per Clerk user/browser.

Implemented on `feature/real-workspace-mvp`:

- Real households are created per authenticated user.
- Manual-entry setup saves household income, Expense Stack, emergency fund, debt, assets, and runway target to Postgres.
- Home/Budget/Wealth/CFO Filter/Optionality are calculated from saved data.
- Mia uses a dynamic household context builder for real `/api/v1/mia/messages` requests.
- Signed-in Mia chat is persisted in server-side `chat_sessions` / `chat_messages`.
- A minimal staff/admin users endpoint exists for invite records.
- Admin cohort management now has a browser UI for creating cohorts, inviting admins/coaches/participants, enforcing role/cohort requirements, sending/resending Resend invite emails when configured, assigning users to cohorts, and seeing high-level setup/readiness status.

Still not real yet:

- Granular add/edit/delete UI for every income/expense/debt/account row beyond the first guided setup form.
- Full coach/admin analytics dashboard beyond basic cohort/user operations.
- Upload/OCR document processing.
- Payments/subscriptions.

## Mrs. Mel's latest feedback

Mrs. Mel's response to the screenshot pack was very positive:

- "This is a great start!"
- "But this is so good man, good work."

Her specific actionable feedback:

- Mia needs the persona brief so the voice sounds local.
- For demo/testing with the ladies, she wants to see Mia give culturally grounded, direct accountability.
- Example direction: Mia should be able to say something like, "Lanya chelu, that purse isn't in the cards right now!"

Product interpretation:

- The visual direction is accepted enough to continue.
- The next product differentiator is Mia's voice and usefulness, not more generic dashboard polish.
- The app should feel like a local Household CFO coach, not a generic robo-advisor.
- Local language should be used carefully: culturally grounded, not cartoonish or overdone.

## Core decision

Move from preview/demo data to a real authenticated household workspace.

Important nuance: do not permanently delete the demo/sample capability. Instead:

- Real logged-in users should use `/api/v1/*` data backed by Postgres.
- Demo/sample data should remain only as a safe preview/sales/screenshot mode.
- Demo data must never be mixed into real participant workspaces.

## PR strategy

Leon prefers fewer PRs, possibly one larger PR.

Recommended approach:

### Best fit: one long-running draft PR with staged commits

Create one branch, for example:

```text
feature/real-workspace-mvp
```

Open one draft PR early and build the full real-mode MVP inside it with clear commits/checkpoints. Merge only when the acceptance criteria are met.

Why this is okay here:

- The real-mode work crosses database, API, frontend, Mia context, and auth boundaries.
- Splitting into too many PRs may create temporary half-real/half-demo states.
- A draft PR still gives review visibility without forcing premature merging.

Risk control inside one PR:

- Keep commits small and named by layer.
- Add tests with each backend capability.
- Keep demo endpoints intact until real endpoints are fully working.
- Avoid committing real financial data or private docs.
- Run full checks before marking ready.

Alternative if the PR becomes too large:

1. Real participant workspace MVP.
2. Coach/admin + deployment hardening.

But the default plan is one draft PR unless it becomes unmanageable.

## Real-mode MVP definition

A real participant can:

1. Sign in through Clerk.
2. Land in their own Household CFO workspace.
3. Enter household/profile details.
4. Enter monthly income.
5. Enter monthly expenses using the Expense Stack.
6. Enter emergency fund/cash accounts.
7. Enter debts.
8. Enter assets/wealth basics.
9. Set a primary goal and optionality scenario.
10. See Home/Budget/Wealth/CFO Filter/Optionality calculated from their data.
11. Ask Mia questions using their own household context.
12. Return later and see their data persisted.

Mrs. Mel/coach/admin can:

1. Invite users or seed invite records.
2. See cohort participants.
3. See completion/readiness at a high level.
4. Avoid seeing unnecessary sensitive detail by default unless explicitly permitted.

## Data model proposal

Minimum tables for real mode:

### households

Represents a participant household/workspace.

Suggested fields:

- `id`
- `name`
- `location`
- `stage`
- `primary_goal`
- `created_by_user_id`
- timestamps

### household_memberships

Connects users to households.

Suggested fields:

- `id`
- `household_id`
- `user_id`
- `role` — `owner`, `partner`, `coach_viewer`
- timestamps

### household_profiles

Profile/onboarding details.

Suggested fields:

- `id`
- `household_id`
- `household_stage`
- `money_stress_level`
- `primary_decision`
- `notes`
- timestamps

### income_sources

User-entered income.

Suggested fields:

- `id`
- `household_id`
- `label`
- `amount_cents`
- `cadence` — monthly, biweekly, weekly, annual, one_time
- `source_type` — job, business, rental, passive, bonus, other
- `active`
- timestamps

### expense_items

Expense Stack items.

Suggested fields:

- `id`
- `household_id`
- `label`
- `amount_cents`
- `cadence`
- `stack_key` — non_discretionary, discretionary, sinking_expected, sinking_unexpected
- `active`
- timestamps

### debts

Debt balances and payments.

Suggested fields:

- `id`
- `household_id`
- `label`
- `balance_cents`
- `minimum_payment_cents`
- `interest_rate_percent`
- `debt_type`
- timestamps

### accounts

Cash, savings, investment, and other account balances.

Suggested fields:

- `id`
- `household_id`
- `label`
- `account_type` — checking, savings, emergency_fund, retirement, investment, property, other
- `balance_cents`
- timestamps

### goals

User goals and optionality targets.

Suggested fields:

- `id`
- `household_id`
- `label`
- `goal_type` — runway, debt_payoff, business_income, purchase, transition, other
- `target_amount_cents`
- `target_months`
- `current_amount_cents`
- `priority`
- timestamps

### chat_sessions / chat_messages

Server-side Mia history for real users.

Suggested `chat_sessions` fields:

- `id`
- `household_id`
- `user_id`
- `title`
- timestamps

Suggested `chat_messages` fields:

- `id`
- `chat_session_id`
- `role` — user, assistant
- `content`
- timestamps

## Backend endpoint plan

Keep existing demo routes for safe preview.

Add real routes under `/api/v1`:

```text
GET    /api/v1/workspace
PATCH  /api/v1/household
GET    /api/v1/profile
PATCH  /api/v1/profile
GET    /api/v1/income-sources
POST   /api/v1/income-sources
PATCH  /api/v1/income-sources/:id
DELETE /api/v1/income-sources/:id
GET    /api/v1/expense-items
POST   /api/v1/expense-items
PATCH  /api/v1/expense-items/:id
DELETE /api/v1/expense-items/:id
GET    /api/v1/debts
POST   /api/v1/debts
PATCH  /api/v1/debts/:id
DELETE /api/v1/debts/:id
GET    /api/v1/accounts
POST   /api/v1/accounts
PATCH  /api/v1/accounts/:id
DELETE /api/v1/accounts/:id
GET    /api/v1/goals
POST   /api/v1/goals
PATCH  /api/v1/goals/:id
DELETE /api/v1/goals/:id
GET    /api/v1/dashboard
GET    /api/v1/budget
GET    /api/v1/wealth
GET    /api/v1/cfo-filter
GET    /api/v1/optionality
GET    /api/v1/mia/messages
POST   /api/v1/mia/messages
```

Possible admin/coach routes:

```text
GET    /api/v1/admin/users
POST   /api/v1/admin/invitations
GET    /api/v1/admin/households
GET    /api/v1/admin/cohort-summary
```

## Backend services needed

### HouseholdWorkspaceResolver

Ensures each signed-in participant has a household workspace and only sees authorized data.

### FinancialSnapshotBuilder

Calculates the normalized household picture from persisted records:

- monthly income
- fixed expenses
- flexible spend
- debt payments
- emergency fund balance
- monthly surplus
- safe-to-spend
- runway months
- readiness label/color

### BudgetBuilder

Builds the Expense Stack from saved expense items.

### WealthBuilder

Builds net worth/liquid net worth from accounts and debts.

### OptionalityBuilder

Calculates the user's transition/jump readiness from runway, monthly need, partner/filler income, and business income target.

### CfoFilterBuilder

Generates recommendations from the user's goals, runway, debt, and surplus.

### MiaContextBuilder

Turns the user's real data into a concise safe prompt context for Mia.

### MiaResponder update

Replace hardcoded demo financial context with dynamic context for `/api/v1/mia/messages`, while keeping demo context for `/api/demo/mia/messages`.

## Frontend plan

### App mode

The frontend should stop fetching `/api/demo/*` for authenticated real users.

Preferred direction:

- When Clerk is not configured locally: allow safe preview/demo mode.
- When Clerk is configured and user is signed in: fetch real `/api/v1/*` workspace data.
- Keep demo fallback explicit, not accidental.

### Onboarding/manual entry

Build a mobile-first setup flow that feels guided by Mia:

1. Household basics.
2. Income.
3. Expense Stack.
4. Emergency fund/cash.
5. Debts.
6. Goals/optionality.
7. Review snapshot.

Important: this should not feel like a giant spreadsheet. The core UX is "Mia helps me build my money picture."

### Screen updates

Home:

- Show real readiness state.
- Show missing-data prompts if setup incomplete.
- CTA: finish profile / ask Mia / update numbers.

My Profile:

- Editable sections for income, expenses, savings/debt, goals.
- Upload cards remain disabled/future until OCR scope is approved.

Budget:

- Expense Stack editor and summary.

Wealth:

- Accounts/debts summary.

CFO Filter:

- Allow a user to test a spending decision with amount + reason.

Optionality:

- Allow user to set transition scenario inputs.

Ask Mia:

- Use real household context.
- Persist chat server-side for signed-in users.
- Keep localStorage only as temporary UI draft/cache if needed.

## Mia local persona direction

Mia should sound local, but not like a caricature.

Rules:

- Direct, warm, practical.
- Validate before coaching.
- One clear next move.
- 3–5 short sentences.
- Plain text, no markdown.
- Use `che’lu` sparingly.
- Use `lanya` only for genuine surprise, accountability, or a notable win/miss.
- Never shame the person; challenge the decision/pattern.
- No regulated financial/tax/legal/investment advice.

Example response for the purse screenshot/demo:

```text
Lanya, che’lu — not this month. The purse is cute, but your runway is still yellow and the debt plan needs breathing room. Put it on the 30-day list; if you still want it after the next pay cycle, we’ll find a clean way to fund it without stealing from your emergency fund.
```

## Data/privacy guardrails

- Do not commit real financial data.
- Do not commit real participant emails beyond safe local seed examples.
- Do not commit statements, pay stubs, receipts, or screenshots containing real private data.
- Keep `docs/HouseholdCFO/` untracked unless files are scrubbed and intentionally added.
- Backend logs should not dump full financial payloads or Mia prompts.
- Upload/OCR should remain disabled in the app until the private S3 document-import workflow is implemented; see `docs/private-document-imports-and-mia-context.md`.

## Testing plan

Backend priority:

- Model validations and ownership rules.
- Request tests for every `/api/v1/*` endpoint.
- Authorization tests: users cannot access another household.
- Calculation service tests for dashboard/budget/wealth/optionality.
- Mia context tests to ensure real data is included and private fields are not over-shared.

Frontend priority:

- TypeScript build.
- Existing design regression checks.
- Add targeted tests for API client mode switching if practical.
- Manual mobile QA for onboarding and Ask Mia.

Full checks before merge:

```bash
cd api && RAILS_ENV=test bundle exec rails test
cd api && bundle exec rubocop
cd api && bundle exec rails zeitwerk:check
cd web && npm run lint
cd web && npm test
cd web && npm run build
git diff --check
```

## Deployment plan

For real users, target:

- Frontend: Netlify or equivalent.
- Backend: Render/Railway/Fly with always-on instance, not sleeping free tier.
- Database: Neon/Render Postgres/Supabase Postgres.
- Auth: Clerk production app.
- AI: OpenRouter key only on backend.

Required production env:

```text
DATABASE_URL
RAILS_ENV=production
RAILS_MASTER_KEY or SECRET_KEY_BASE
FRONTEND_URL / FRONTEND_URLS
CLERK_ISSUER or CLERK_JWKS_URL
CLERK_SECRET_KEY
OPENROUTER_API_KEY
OPENROUTER_MODEL=google/gemini-2.5-flash
VITE_API_BASE_URL
VITE_CLERK_PUBLISHABLE_KEY
```

## Acceptance criteria for the real-mode PR

The PR is ready when:

- A new invited participant can sign in and create/edit their own household data.
- A second participant can sign in and does not see the first participant's data.
- Home/Budget/Wealth/CFO Filter/Optionality are based on saved data.
- Mia responds using the signed-in household's saved context.
- Mia's voice has the local persona layer Mrs. Mel asked for.
- Chat history is server-persisted for authenticated users.
- Demo/sample data still exists only as an explicit preview path.
- Upload/OCR remains clearly disabled unless/until the private S3 document-import workflow is implemented.
- All checks pass.
- No private financial docs/data/secrets are committed.

## Suggested build checklist for one draft PR

- [ ] Create `feature/real-workspace-mvp` branch.
- [ ] Add real-mode schema/migrations.
- [ ] Add models and ownership validations.
- [ ] Add financial calculation services.
- [ ] Add `/api/v1` workspace endpoints.
- [ ] Add request/model/service tests.
- [ ] Update frontend API client to support real workspace mode.
- [ ] Build guided onboarding/manual entry screens.
- [ ] Wire existing screens to real data.
- [ ] Add server-side Mia chat sessions/messages.
- [ ] Add dynamic Mia context builder and local persona prompt.
- [ ] Add admin/coach invite/cohort summary basics.
- [ ] Update README/setup docs.
- [ ] Run full checks.
- [ ] Generate new screenshot pack with demo-safe sample data.
- [ ] Mark PR ready for review.

## Deferred until after real-mode MVP

- Private S3 document imports, OCR/extraction, and review-before-apply are now the next planned feature; see `docs/private-document-imports-and-mia-context.md`.
- Payments/subscriptions.
- Full multi-tenant white-label coach skin engine.
- PDF export.
- SMS/WhatsApp reminders.
- Advanced analytics/cohort outcomes reporting.
