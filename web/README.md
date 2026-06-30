# Household CFO Web

React/Vite participant workspace for Household CFO Method powered by VERA. The UI supports safe demo preview mode locally and real participant workspaces when Clerk is configured.

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
VITE_SITE_URL=http://localhost:5173
# VITE_CLERK_PUBLISHABLE_KEY=pk_test_...
# VITE_PUBLIC_POSTHOG_KEY=phc_...
VITE_PUBLIC_POSTHOG_UI_HOST=https://us.posthog.com
```

When `VITE_CLERK_PUBLISHABLE_KEY` is not set, the app runs in local preview mode without auth and fetches `/api/demo/*`. Hosted/cohort environments should configure Clerk, rely on `/api/v1/auth/me` to verify the invited local user, and fetch the user's real `/api/v1/workspace` data.

Set `VITE_SITE_URL` to the production Netlify URL/custom domain before building so generated `robots.txt`, `sitemap.xml`, and runtime canonical metadata point at the right host. In production, `VITE_API_BASE_URL` must point at the Render API; if it is missing, browser uploads and authenticated API calls will try localhost and fail with a fetch error.

PostHog analytics is disabled unless `VITE_PUBLIC_POSTHOG_KEY` is present. Production custom domains automatically use the same-origin Netlify proxy at `/vera-insights`; local/dev and Netlify deploy previews use the appropriate direct PostHog ingestion host. Session replay is always enabled when analytics is enabled and masks all inputs/text by default because the app handles financial context.

Admins see an additional Admin tab after sign-in. Use it to create cohorts, review the role/cohort matrix, invite additional admins/coaches/participants, resend invite emails, and assign users to cohorts without Rails console commands. Admin cohort assignment is optional; coach and participant assignment is required by the API.

## PWA + SEO

The app includes a web manifest, install icons, social sharing image, Netlify redirects, generated `robots.txt`/`sitemap.xml`, and a small production-only service worker for the application shell. Run `npm run build` to verify the PWA and SEO assets are copied into `dist/`.

## Checks

```bash
npm run lint
npm test
npm run build
npm audit --audit-level=moderate
```

## Data safety

Use demo-safe sample data only. Do not add real client financial data, statements, pay stubs, credentials, or private documents to the frontend.
