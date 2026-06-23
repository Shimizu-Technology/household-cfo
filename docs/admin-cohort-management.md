# Admin cohort management

Updated: 2026-06-23

Household CFO now includes a browser-based Admin tab for owner admins. This avoids local `rails runner` invite commands during testing and gives Mrs. Mel/Leon the foundation for pilot cohort operations.

## Owner bootstrap

`bin/rails db:seed` always creates or repairs an admin invite for:

```text
shimizutechnology@gmail.com
```

The seed is invite-only. The admin still signs in with Clerk using that same email. On first sign-in, the API links the Clerk user ID to the pending local admin record.

Additional bootstrap admins can be added when seeding:

```bash
SEED_ADMIN_EMAILS=owner@example.com,partner@example.com bin/rails db:seed
```

## Admin UI

After an invited admin signs in, the participant nav gets an additional `Admin` tab.

Admins can:

- create cohorts,
- set cohort status/dates/notes,
- invite users as `admin`, `coach`, or `participant`,
- assign invited users to a cohort,
- update user role/status/cohort assignment,
- see high-level setup completion/readiness without exposing detailed household financial rows.

## API shape

Admin endpoints are Clerk-authenticated.

```text
GET    /api/v1/admin/cohorts
POST   /api/v1/admin/cohorts
GET    /api/v1/admin/cohorts/:id
PATCH  /api/v1/admin/cohorts/:id
GET    /api/v1/admin/users
POST   /api/v1/admin/users
PATCH  /api/v1/admin/users/:id
```

`/api/v1/admin/cohorts` is admin-only. User invite management remains staff-aware at the API layer, but the current web Admin tab is shown only to admins.

## Safety constraints

- The UI does not send real invitation emails yet; it creates invite records that Clerk sign-in can link by email.
- The UI blocks self-demotion/revocation at the backend.
- The backend prevents removing the last active admin.
- Cohort dashboards show completion/readiness summaries, not detailed financial entries.
- Do not add real participant financial data to seeds, tests, docs, or screenshots.

## Local blank-slate flow

1. Configure Clerk in `api/.env` and `web/.env`/`web/.env.local`.
2. Reset local DB if needed:

   ```bash
   cd api
   bin/rails db:drop db:create db:migrate db:seed
   ```

3. Start Rails and Vite.
4. Sign in with `shimizutechnology@gmail.com`.
5. Open the `Admin` tab.
6. Create a test cohort.
7. Invite a fake participant email into that cohort.
8. Sign out, sign in as the participant, and test the blank workspace/setup/Mia flow.
