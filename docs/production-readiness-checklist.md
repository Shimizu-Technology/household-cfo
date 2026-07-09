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

   The API also ships safe defaults for `https://householdcfomethod.com`, `https://www.householdcfomethod.com`, and `https://household-cfo.netlify.app`, but Render env should still include the canonical production domain so future domains/previews are explicit.

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
VITE_PUBLIC_POSTHOG_UI_HOST=https://us.posthog.com
```

The repo ships Netlify proxy rules for `/vera-insights/*` so production custom-domain events go through the app domain instead of directly to `us.i.posthog.com`. Host selection is automatic: custom-domain production uses `/vera-insights`; local/dev and `.netlify.app` deploy previews use direct PostHog ingestion so previews do not depend on the custom-domain proxy.

Privacy defaults in code:

- Analytics is disabled unless a PostHog key is present.
- Autocapture is off; only safe product events are tracked.
- User identification sends app role/status only, not email/name/financial values.
- Session replay is enabled whenever analytics is enabled and masks all inputs/text.
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

## Upload blocker triage

If production uploads fail with `Failed to fetch` or a generic browser network error:

1. Confirm Netlify has `VITE_API_BASE_URL=https://your-render-api.onrender.com` and has been redeployed after the env change.
2. Confirm Render has `FRONTEND_URL` / `FRONTEND_URLS` for `https://householdcfomethod.com` and any preview host being tested.
3. Confirm Render has private S3 configuration: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `AWS_S3_BUCKET`, and `AWS_S3_PREFIX`.
4. Confirm Render has backend-only OpenRouter voice transcription when voice is enabled: `OPENROUTER_API_KEY`, optional `OPENROUTER_TRANSCRIPTION_MODEL=openai/whisper-large-v3`, and optional `MIA_TRANSCRIPTION_LANGUAGE=en`.
5. Check Render logs for `[S3Service] Upload failed`, CORS errors, Clerk authorization errors, transcription configuration errors, or `Private S3 document storage is not configured`.
6. Test an explicit upload from `https://householdcfomethod.com` using a demo-safe `.xlsx` or image file.

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
- Ask Mia voice input records, transcribes, puts editable transcript in the composer, and does not auto-confirm actuals.
- Ask Mia attachment flow creates a reviewable import.
- Admin tab visible only to admins; participant cannot see it.
- Admin can create cohort, invite participant, resend invite, revoke/remove access.
