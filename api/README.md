# Household CFO API

Rails API for Household CFO powered by VERA. It serves the demo-safe Mia/Household CFO preview data today and now includes the Clerk-backed user/auth foundation for cohort access.

## Stack

- Ruby/Rails API
- PostgreSQL
- Clerk JWT verification through JWKS
- Resend invite email delivery for admin-created invitations
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

## Mia persona setup

The default Mia coach persona lives in `config/mia_personas.yml`. Set `MIA_PERSONA_ID` to select a different configured persona at runtime; safety and financial-boundary rules stay in code and cannot be overridden by persona config.

## Clerk setup

Set either `CLERK_JWKS_URL` or `CLERK_ISSUER` in the API environment. For invite-only linking by email, also set `CLERK_SECRET_KEY` so the API can fetch Clerk profile/email details when the default token omits them.

Useful local bootstrap options:

```bash
bin/rails db:seed # creates the shimizutechnology@gmail.com admin invite when missing
SEED_ADMIN_EMAIL=you@example.com bin/rails db:seed
SEED_ADMIN_EMAILS=you@example.com,partner@example.com bin/rails db:seed
# or temporarily:
CLERK_BOOTSTRAP_ADMIN_EMAILS=you@example.com
```

After the owner admin signs in, use the Admin tab in the web app to create cohorts and invite additional admins, coaches, and participants. Do not commit Clerk keys, Resend keys, participant financial data, or private documents.

## Resend invite emails

Admin-created invites and resend actions call Resend directly when configured:

```bash
RESEND_API_KEY=re_...
RESEND_FROM_EMAIL="Household CFO <noreply@example.com>"
# or MAILER_FROM_EMAIL=noreply@example.com
FRONTEND_URL=http://localhost:5173
```

The Admin UI requests invite email delivery by default. If Resend is not configured, invitation records are still created for Clerk email-linking, but the email status is stored as `failed` with a clear configuration error. Admins can explicitly uncheck email delivery for a create action; that intentional no-send path is stored as `skipped`. Each send/resend writes an immutable `invitation_email_attempts` audit row while summary status fields stay on `users` for the Admin UI.

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
- `GET/POST/PATCH /api/v1/admin/users` and `POST /api/v1/admin/users/:id/resend_invitation` — staff/admin invite records, Resend delivery status, role/status management, and cohort assignment.
- `GET/POST/PATCH /api/v1/admin/cohorts` — admin-only cohort creation and cohort metadata management.
- `GET /api/demo/*` — demo-safe Household CFO screens; public only when Clerk is not configured for local preview.
- `POST /api/demo/mia/messages` — demo Mia response endpoint; uses OpenRouter when configured and deterministic fallback otherwise.
