# Admin cohort management

Updated: 2026-06-23

Household CFO now includes a browser-based Admin tab for owner admins. This avoids local `rails runner` invite commands during testing and gives Mrs. Mel/Leon the foundation for pilot cohort operations.

## Owner bootstrap

`bin/rails db:seed` creates a default admin invite when one is missing for:

```text
shimizutechnology@gmail.com
```

The seed is invite-only. The admin still signs in with Clerk using that same email. On first sign-in, the API links the Clerk user ID to the pending local admin record. Re-running seeds fills missing bootstrap fields, but it does not undo an intentional role/status change made through the admin UI.

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
- send invitation emails by default through Resend, with an explicit no-email checkbox for admin-only exceptions,
- resend invitation emails and review delivery history,
- assign invited users to one or more cohorts,
- remove users from a selected cohort,
- cancel pending invites by revoking access and clearing cohort assignments,
- update user role/status/cohort assignments,
- review the collapsible role matrix that explains cohort requirements,
- see high-level setup completion/readiness without exposing detailed household financial rows.

Role/cohort policy is backend-enforced:

- `admin`: cohort assignment is optional.
- active `coach`: at least one cohort is required.
- active `participant`: at least one cohort is required.
- `revoked` users may have no cohorts so admins can cancel pending invites or remove someone from their last cohort.

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
POST   /api/v1/admin/users/:id/resend_invitation
```

`/api/v1/admin/cohorts` is admin-only. User invite management remains staff-aware at the API layer, but the current web Admin tab is shown only to admins. Create/resend responses include `invitation_sent`, `invitation_status`, and `invitation_error` so the UI can report whether Resend actually delivered the email.

## Invitation emails

Invite emails use Resend directly from the Rails API. The Admin UI sends by default; if Resend is missing, invites are still created for Clerk linking but email delivery is marked `failed` with the missing configuration reason. Admins can explicitly uncheck email delivery when creating an invite; that intentional no-send path is marked `skipped`.

```bash
RESEND_API_KEY=re_...
RESEND_FROM_EMAIL="Household CFO <noreply@example.com>"
# or MAILER_FROM_EMAIL=noreply@example.com
FRONTEND_URL=http://localhost:5173
```

Email delivery metadata is summarized on the invited user (`invitation_email_status`, provider id, last attempt/sent timestamps, and last sender). Each create/resend also writes an immutable `invitation_email_attempts` audit row so admins can retry delivery without losing history or using Rails console commands.

## Safety constraints

- The UI requests real invitation emails by default; missing Resend config is surfaced as a failed delivery instead of looking intentional.
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
8. Confirm the invite email arrives. If the UI reports delivery failed because `RESEND_API_KEY` is missing, add the key to `api/.env` and restart Rails before retrying.
9. Sign out, sign in as the participant, and test the blank workspace/setup/Mia flow.
