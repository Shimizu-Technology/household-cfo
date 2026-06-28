# Production readiness checklist

Use this after each production deploy and whenever the custom domain/Clerk/PostHog settings change.

References used:

- Brain-Dump starter app: `PWA_SETUP_GUIDE.md`, `ANALYTICS_SETUP_GUIDE.md`, `SEO_SETUP_GUIDE.md`, `CLERK_AUTH_SETUP_GUIDE.md`, `DEPLOYMENT_GUIDE.md`
- Existing Shimizu patterns: `marianas-open` PostHog/SEO/Netlify redirects, `fd-alumni-hub` analytics/SEO manager

## Netlify + GoDaddy custom domain

1. In Netlify, open the Household CFO site → **Domain settings** → **Add custom domain**.
2. Add the purchased domain and choose the primary host (`example.com` or `www.example.com`).
3. If keeping DNS at GoDaddy, add these DNS records in GoDaddy:

   | Type | Name | Value |
   | --- | --- | --- |
   | A | `@` | `75.2.60.5` |
   | CNAME | `www` | the Netlify site host, e.g. `household-cfo.netlify.app` |

   Remove GoDaddy parking/forwarding records that conflict with `@` or `www`.
4. Alternative: switch nameservers to Netlify DNS, but only if there are no existing email/DNS records that need to stay at GoDaddy.
5. Wait for Netlify DNS verification and SSL certificate provisioning.
6. Update Netlify environment:

   ```bash
   VITE_SITE_URL=https://your-domain.com
   VITE_API_BASE_URL=https://your-render-api.onrender.com
   VITE_CLERK_PUBLISHABLE_KEY=pk_live_...
   ```

7. Update Render API CORS:

   ```bash
   FRONTEND_URL=https://your-domain.com
   FRONTEND_URLS=https://your-domain.com,https://www.your-domain.com,https://your-netlify-site.netlify.app
   ```

8. Redeploy web and API after env changes.

## Clerk production setup

1. Create a separate **production** Clerk application.
2. Enable the intended sign-in methods, at minimum email address. Add Google only if Mrs. Mel wants it for the first cohort.
3. Configure allowed origins/redirects for:
   - `https://your-domain.com`
   - `https://www.your-domain.com` if used
   - Netlify deploy preview URL only if previews need auth testing
4. Copy production keys:
   - Netlify: `VITE_CLERK_PUBLISHABLE_KEY=pk_live_...`
   - Render: `CLERK_SECRET_KEY=sk_live_...`
5. Set one backend verifier value:
   - Preferred simple option: `CLERK_ISSUER=https://<your-production-clerk-issuer>`
   - Or: `CLERK_JWKS_URL=https://<issuer>/.well-known/jwks.json`
6. Do **not** configure or require a frontend Clerk JWT template for this app.
7. Seed or create the owner/admin user, then use the Admin tab for cohorts and participant invites.
8. Smoke test: invited user can sign in; uninvited Clerk user is rejected by `/api/v1/auth/me`.

## PostHog analytics/session replay

Netlify env:

```bash
VITE_PUBLIC_POSTHOG_KEY=phc_...
# Optional override. Production defaults to the same-origin Netlify proxy at /vera-insights.
VITE_PUBLIC_POSTHOG_HOST=/vera-insights
VITE_PUBLIC_POSTHOG_UI_HOST=https://us.posthog.com
# Optional; default is off for financial privacy.
VITE_PUBLIC_POSTHOG_SESSION_REPLAY=true
```

The repo ships Netlify proxy rules for `/vera-insights/*` so production events go through the custom domain instead of directly to `us.i.posthog.com`. This proxy requires the custom domain; if testing analytics on a `.netlify.app` deploy preview, either keep PostHog disabled there or temporarily set `VITE_PUBLIC_POSTHOG_HOST=https://us.i.posthog.com` for that context.

Privacy defaults in code:

- Analytics is disabled unless a PostHog key is present.
- Autocapture is off; only safe product events are tracked.
- User identification sends app role/status only, not email/name/financial values.
- Session replay is opt-in and masks all inputs/text.
- Query strings and source document URLs are redacted before replay/network capture.

## PWA checks

Run after deploy:

1. Open Chrome DevTools → **Application**.
2. Confirm `manifest.webmanifest` loads with 192x192 and 512x512 icons.
3. Confirm service worker registers in production.
4. Run Lighthouse PWA audit.
5. Install from desktop Chrome and iOS Safari **Add to Home Screen**.

## SEO checks

After `VITE_SITE_URL` is set and the web app redeploys:

1. Visit:
   - `https://your-domain.com/robots.txt`
   - `https://your-domain.com/sitemap.xml`
   - `https://your-domain.com/og-image.png`
2. Confirm `sitemap.xml` uses the custom domain.
3. Confirm page source has title/description/Open Graph/Twitter metadata.
4. Add Google Search Console property for the custom domain.
5. Verify with DNS TXT at GoDaddy or the provided HTML meta tag.
6. Submit `https://your-domain.com/sitemap.xml`.

## Full production smoke test

- Clerk sign-in/sign-out.
- Invited participant lands in the real workspace.
- Uninvited account is denied.
- Home/Budget/Wealth/CFO Filter/Optionality render from saved data.
- My Profile manual setup saves and refreshes Mia context.
- Excel budget template downloads.
- Private document upload → review → edit → apply.
- Applied corrections update saved household numbers.
- Source preview/download/delete work only from explicit controls.
- Ask Mia persists chat and uses approved context.
- Ask Mia attachment flow creates a reviewable import.
- Admin tab visible only to admins; participant cannot see it.
- Admin can create cohort, invite participant, resend invite, revoke/remove access.
