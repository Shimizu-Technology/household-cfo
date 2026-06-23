# Household CFO powered by VERA

Phase 1 Household CFO cohort MVP and FinCon-ready VERA foundation for Melanie Mendiola / Household CFO Method.

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
- Server-persisted Mia chat for signed-in users, with dynamic household context
- Clerk auth plumbing with invite-only local `users` records
- Browser-based admin console for cohorts, admin/coach/participant invite records, and cohort assignment
- PostgreSQL database configuration for local, test, and production-like environments
- CI checks for Rails security/lint/tests and web lint/test/build/audit

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
4. Run `bin/rails db:seed` to create the default owner admin invite for `shimizutechnology@gmail.com`, then use the Admin tab to invite additional admins, coaches, and participants into cohorts.
5. Uninvited Clerk sessions are rejected by `/api/v1/auth/me`.

## Safety / data rule

Use demo-safe sample data only. Do not commit real client financial data, credentials, API keys, statements, pay stubs, or private documents.

## Next phase

The active real-mode build plan and Mia persona template live at:

```text
docs/real-mode-build-plan.md
docs/mia-persona-template.md
docs/admin-cohort-management.md
```

## Deferred until after the real-mode MVP

- Stripe subscriptions
- SMS reminders
- Real OCR/document parsing
- Full white-label skin engine
- Advanced coach/admin onboarding workflows
