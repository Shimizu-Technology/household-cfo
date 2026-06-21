# Household CFO API

Rails API for Household CFO powered by VERA. It serves the demo-safe Mia/Household CFO preview data today and now includes the Clerk-backed user/auth foundation for cohort access.

## Stack

- Ruby/Rails API
- PostgreSQL
- Clerk JWT verification through JWKS
- OpenRouter optional fallback for Mia responses

## Local setup

```bash
cd api
bundle install
cp .env.example .env # optional
bin/rails db:prepare
bin/rails server -p 3000
```

If your local PostgreSQL server needs explicit credentials, set `DATABASE_HOST`, `DATABASE_USERNAME`, and `DATABASE_PASSWORD` in `api/.env`.

## Clerk setup

Set either `CLERK_JWKS_URL` or `CLERK_ISSUER` in the API environment. For invite-only linking by email, also set `CLERK_SECRET_KEY` so the API can fetch Clerk profile/email details when the default token omits them.

Useful local bootstrap options:

```bash
SEED_ADMIN_EMAIL=you@example.com bin/rails db:seed
# or temporarily:
CLERK_BOOTSTRAP_ADMIN_EMAILS=you@example.com
```

Do not commit Clerk keys, real participant emails, or private financial data.

## Tests and checks

```bash
bundle exec rails test
bundle exec rails zeitwerk:check
bundle exec rubocop
bundle exec brakeman --no-pager
bundle exec bundler-audit check --update
```

## Current API shape

- `GET /api/v1/auth/me` — verifies the Clerk bearer token and returns the local user.
- `GET /api/v1/workspace` — returns the authenticated user's real Household CFO workspace from Postgres.
- `PATCH /api/v1/workspace/setup` — saves the first real-mode manual-entry numbers for a participant household.
- `GET /api/v1/profile`, `/dashboard`, `/budget`, `/wealth`, `/cfo-filter`, `/optionality` — real calculated workspace views.
- `GET/POST/DELETE /api/v1/mia/messages` — server-persisted Mia chat using the user's household context.
- `GET /api/demo/*` — demo-safe Household CFO screens; public only when Clerk is not configured for local preview.
- `POST /api/demo/mia/messages` — demo Mia response endpoint; uses OpenRouter when configured and deterministic fallback otherwise.
