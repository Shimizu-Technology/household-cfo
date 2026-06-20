# Household CFO powered by VERA

Phase 1 Household CFO cohort MVP and FinCon-ready VERA foundation for Melanie Mendiola / Household CFO Method.

This repo is intentionally production-shaped, not a throwaway prototype:

```text
household-cfo/
  api/   Rails API + PostgreSQL
  web/   React + Vite + TypeScript
  docs/  build plans, product notes, screenshots
```

## Tuesday sprint goal

By Tuesday, produce a working local vertical slice with polished screenshot-ready screens:

- Coming Soon / Landing
- Home Dashboard
- My Profile
- Ask Mia
- Optionality
- CFO Filter
- simple Admin/Cohort preview if time allows

The Tuesday target is demo/screenshot readiness from the real app foundation, not full production SaaS.

## Deferred until after Tuesday

- Stripe subscriptions
- Twilio/SMS reminders
- real OCR/document parsing
- full production auth hardening
- full white-label skin engine
- coach onboarding

## Local setup

### API

```bash
cd api
bundle install
bin/rails db:prepare
bin/rails server -p 3000
```

### Web

```bash
cd web
npm install
npm run dev
```

Default local URLs:

```text
API: http://localhost:3000
Web: http://localhost:5173
```

## Safety / data rule

Use demo-safe sample data only. Do not commit real client financial data, credentials, API keys, or private documents.
