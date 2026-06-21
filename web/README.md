# Household CFO Web

React/Vite participant workspace for Household CFO powered by VERA. The UI is a polished first-cohort preview with Clerk auth support when configured.

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
# VITE_CLERK_JWT_TEMPLATE=household-cfo-api
```

When `VITE_CLERK_PUBLISHABLE_KEY` is not set, the app runs in local preview mode without auth. Hosted/cohort environments should configure Clerk and rely on `/api/v1/auth/me` to verify the invited local user.

## Checks

```bash
npm run lint
npm test
npm run build
npm audit --audit-level=moderate
```

## Data safety

Use demo-safe sample data only. Do not add real client financial data, statements, pay stubs, credentials, or private documents to the frontend.
