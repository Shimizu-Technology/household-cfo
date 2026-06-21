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

The app is a polished first-cohort preview, not a full production financial platform yet. It includes:

- Home, Ask Mia, My Profile, Budget, Wealth, CFO Filter, and Optionality screens
- Demo-safe Household CFO sample data
- Clerk auth plumbing with invite-only local `users` records
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
4. Seed or invite local users before access; uninvited Clerk sessions are rejected by `/api/v1/auth/me`.

## Safety / data rule

Use demo-safe sample data only. Do not commit real client financial data, credentials, API keys, statements, pay stubs, or private documents.

## Deferred until a later phase

- Stripe subscriptions
- SMS reminders
- Real OCR/document parsing
- Full participant household persistence
- Full white-label skin engine
- Coach/admin onboarding workflows
