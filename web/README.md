# Household CFO Web

React/Vite participant workspace for Household CFO powered by VERA. The UI supports safe demo preview mode locally and real participant workspaces when Clerk is configured.

## Local setup

```bash
cd web
npm install
cp .env.example .env.local # optional
npm run dev
```

Default URLs:

- Web: `http://localhost:5173`
- API: `http://localhost:3000`

## Environment

```bash
VITE_API_BASE_URL=http://localhost:3000
# VITE_CLERK_PUBLISHABLE_KEY=pk_test_...
```

When `VITE_CLERK_PUBLISHABLE_KEY` is not set, the app runs in local preview mode without auth and fetches `/api/demo/*`. Hosted/cohort environments should configure Clerk, rely on `/api/v1/auth/me` to verify the invited local user, and fetch the user's real `/api/v1/workspace` data.

Admins see an additional Admin tab after sign-in. Use it to create cohorts, review the role/cohort matrix, invite additional admins/coaches/participants, resend invite emails, and assign users to cohorts without Rails console commands. Admin cohort assignment is optional; coach and participant assignment is required by the API.

## PWA

The app includes a web manifest, install icons, and a small production-only service worker for the application shell. Run `npm run build` to verify the PWA assets are copied into `dist/`.

## Checks

```bash
npm run lint
npm test
npm run build
npm audit --audit-level=moderate
```

## Data safety

Use demo-safe sample data only. Do not add real client financial data, statements, pay stubs, credentials, or private documents to the frontend.
