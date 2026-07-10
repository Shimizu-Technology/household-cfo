# Household CFO Method powered by VERA

Phase 1 Household CFO Method cohort MVP and FinCon-ready VERA foundation for Melanie Mendiola.

This repo is production-shaped while the visible data remains demo-safe:

```text
household-cfo/
  api/   Rails API + PostgreSQL + Clerk JWT verification
  web/   React + Vite + TypeScript + optional ClerkProvider
  docs/  build plans, product notes, screenshots
```

## Current status

The app is now moving from polished preview toward real cohort MVP. It includes:

- Home, Ask Mia, My Profile, Budget, Wealth, CFO Filter, and Optionality screens
- Demo-safe Household CFO sample data for preview/screenshot mode
- Real authenticated participant workspaces backed by PostgreSQL
- Manual-entry household setup for income, Expense Stack, emergency fund, debt, assets, and runway target
- Dashboard/Budget/Wealth/CFO Filter/Optionality calculations from saved user data
- Server-persisted Mia chat for signed-in users: the UI shows the full conversation since the last clear, while model context stays token-bounded with versioned active-thread state, model-backed structured intent resolution, and approved household context
- Private S3-backed financial document imports with upload, source preview/download/delete, review/edit/apply, and Ask Mia attachment flow
- Backend-only Mia voice transcription through OpenRouter STT: browser recording uploads to Rails, transcript is visible/editable, and typed/voice messages use the same review-before-apply flow
- Clerk auth plumbing with invite-only local `users` records
- Browser-based admin console for cohorts, role/cohort policy, admin/coach/participant invite records, Resend invite emails, and cohort assignment
- PostgreSQL database configuration for local, test, and production-like environments
- CI checks for Rails security/lint/tests and web lint/test/build/audit
- YAML-backed Mia response and multi-turn intent evals for spending reports, pending-draft corrections, contextual budget edits, recall, voice-created spend, and job/bill coaching boundaries

## Local setup

### API

```bash
cd api
bundle install
cp .env.example .env # optional
bin/rails db:prepare
bin/rails server -p 3000
```

### Web

```bash
cd web
npm install
cp .env.example .env.local # optional
npm run dev
```

Default local URLs:

```text
API: http://localhost:3000
Web: http://localhost:5173
```

## Clerk auth

Local preview works without Clerk. For hosted/cohort environments:

1. Set `VITE_CLERK_PUBLISHABLE_KEY` in the web app.
2. Set `CLERK_JWKS_URL` or `CLERK_ISSUER` in the API.
3. Set `CLERK_SECRET_KEY` so the API can fetch Clerk profile/email details when the default token omits them.
4. Set `RESEND_API_KEY` and `RESEND_FROM_EMAIL`/`MAILER_FROM_EMAIL` in the API to deliver invite emails. The Admin UI requests email delivery by default; if Resend is missing, the invite is saved but marked as failed so the configuration issue is visible.
5. Run `bin/rails db:seed` to create the default owner admin invite for `shimizutechnology@gmail.com`, then use the Admin tab to invite additional admins, coaches, and participants into cohorts.
6. Uninvited Clerk sessions are rejected by `/api/v1/auth/me`.

## Safety / data rule

Use demo-safe sample data only. Do not commit real client financial data, credentials, API keys, statements, pay stubs, or private documents. Runtime document uploads use private S3 storage; never place real financial documents in git.

## Next phase

The active real-mode build plan, Mia persona template, admin plan, production checklist, and post-PR #31 roadmap live at:

```text
docs/real-mode-build-plan.md
docs/mia-persona-template.md
docs/admin-cohort-management.md
docs/private-document-imports-and-mia-context.md
docs/production-readiness-checklist.md
docs/post-pr29-roadmap.md
docs/mia-memory-and-supervised-actions.md
```

## Mia eval harness

Real-world response prompts live in `api/test/evals/mia_eval_cases.yml`. Multi-turn intent/reference fixtures live in `api/test/evals/mia_intent_cases.yml` and cover contextual pronouns, confirmations, recall, pending transaction corrections, clarification, and reuse of pending review cards. The test harness validates expected behavior and forbidden claims without frontend AI calls or live OpenRouter dependencies.

## Next product direction

After PR #31, the next planned build tracks are:

1. Production smoke test the merged voice/document/transaction loop.
2. Add supervised Mia action drafts so Mia can propose budget/category edits for review before Rails applies them.
3. Discuss Mia Memory with Mrs. Mel, then build a visible/user-controlled Memory MVP.
4. Polish the annual budget UX, warm neutral visual system, and pilot-ready review flows.

## Deferred until after the real-mode MVP

- Stripe subscriptions
- SMS reminders
- Production OCR coverage beyond the current private import/extraction workflow
- Full white-label skin engine
- Advanced coach/admin onboarding workflows
