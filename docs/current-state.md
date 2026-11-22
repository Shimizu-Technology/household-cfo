# Household CFO current state

Updated: 2026-10-18

This is the canonical implementation-status document for Household CFO Method. Product briefs and older PR roadmaps remain useful historical context, but this file is the source of truth for what is built, merged, locally proven, production-proven, and still conceptual.

## Product center

Mrs. Mel's intended operating rhythm is:

```text
Annual household plan
→ conversational, voice, receipt, or statement capture
→ Mia drafts and categorizes
→ the Household CFO reviews
→ Rails confirms actuals or plan changes
→ statements reconcile prior activity into the correct months
→ Mia coaches from approved numbers and patterns
```

The transaction loop and conversation loop are the core. Wealth, CFO Filter, and Optionality support the method, but they should not obscure review work, month/year position, or the next CFO move.

## August 8 product direction

Mrs. Mel reframed the immediate validation and the longer-term platform direction in the August 8 meeting:

- The pre-FinCon validation is a focused group of about four women, not the earlier 16–21-person rollout.
- The first-session hook is Mia as a culturally authentic coach between human coaching sessions. The app should lead with dialogue and the clearest money-in/money-out picture, not a tour of every module.
- Uploads from both Ask Mia and My Profile must be treated as a release blocker until real-device production checks prove that supported spreadsheets and images can be read, reviewed, and retried safely. (Update, October 2026: the bug that made every PDF/image upload fail to complete was fixed in PR #193, and later upload rounds hardened review and errors in #197 and #204. Real-device production checks are still outstanding.)
- FinCon, September 16–18, is a tablet/phone demonstration and founding-coach recruitment milestone. The operating targets discussed were three coaches by December and ten by spring.
- The eventual product is modular coach infrastructure: a coach can configure which modules are visible and build an AI persona from a questionnaire, coaching sources/transcripts, vetted financial sources, and carefully governed cultural/style guidance.
- That coach-persona, module-configuration, and white-label system is a separate product track. PR #48 only prepares a dependable participant pilot and captures the evidence needed to design that system responsibly.

This section supersedes the older cohort-size and setup/upload-first assumptions in historical roadmaps.

## October 2026: BOG pilot readiness

Status as of October 18, 2026 (Guam). The BOG savings challenge (30 participants, 90 days, suggested $500 target) is built and has been rehearsed end to end locally. It is not launched: no invitations have gone out, Mel has not accepted the flow, and no real-phone journey has been run. Sign-in is WorkOS only.

### Built (PRs #193-#208, all merged)

- Uploads: every PDF/image upload completes again (#193); reviewable bills, plain errors and sturdier batches (#197); manual and upload leftovers including F8/F9 (#204). Plaid sync no longer counts transfers and card payments as spending (#199). Manual flows: reopen/void, restore ignored, correct amount limits and two-tab edits (#200, #201).
- Mia: alert when the AI provider refuses calls (#194); crisis responses for common texting slang (#195) and broader crisis phrases (#207); fallbacks that never echo the message (#196); setup, no-debt and follow-up routing fixes (#198); newest reply stays visible, stale cards close (#205).
- Challenge scoping: Mia, chat and drafts follow the savings challenge, with an "opens soon" state that refuses everything until the challenge is opened (#202).
- Admin controls: the admin chooses the savings experience and opens or pauses the challenge, with a recorded reason and audit history; admin only (#203). While paused, participants can only export their own data, and a first purchase can be logged without choosing a category (#208).
- Program ownership: the admin names the program owner by email at creation; the owner is added as cohort coach automatically and loses that access if demoted (#206). The owner can build and publish the persona, pick the Savings experience, and seal and launch herself.
- Mia challenge answers: deterministic answers for credit card, loan and hard-day questions (#207).

### Proven locally

- Full BOG rehearsal on main 6068ee16 (before #207 and #208): 53 pass, 3 fail, 5 blocked across journeys A-I. All 3 failures and the related follow-ups were fixed in #207 and #208. The rehearsal covered admin-created program with Mel as owner, Mel's own setup and launch, 8 invited participants, admin opening with audit history, the opens-soon state, joining with a $500, $300 or postponed target, daily purchases (place, optional feelings), no-spend days, missed days staying unknown, and pause/reopen. Money agreed everywhere it was shown: a $100 contribution, $25.50 evidence and a $25 withdrawal gave $75 reported and $0.50 supported in the UI, API, Mia, coach summary and Day 30 snapshot. An optional $300 card with unknown APR produced no invented ranking or payoff. Exports exclude feelings by default. The coach sees no amounts until a scoped grant and revoking works. The sponsor report is suppressed under 5 consenting participants. The Day 30 checkpoint stays frozen after a later contribution. The default program stays a challenge and chats stay separate.
- Not tested in the rehearsal: full approved baseline from an upload, a positive sponsor report with at least 5 consenting approved checkpoints, sealed Day 60/90 report contents, capacity 30, real invite email delivery, Mel's seal button on a later real date, real phones.
- 30-person Mia load test (local, single process): with the default concurrency of 4, 10 of 30 simultaneous users got canned replies; with 8, none did. That covered one simultaneous message per user on a local machine, not sustained load: in that burst a single web service with in-process jobs returned no errors, though other requests waited up to about 30 seconds behind Mia.
- Manual QA re-test F1-F7 passes; chat and upload QA rounds were run and their findings fixed.
- Evidence lives in local QA folders and is not committed. See `docs/bog-pilot/readiness-evidence.md` (E38).

### Production-verified

- The merged changes are deployed and health returns 200.
- On October 17 production was set to `MIA_PROVIDER_MAX_CONCURRENCY=8` and `MIA_PROVIDER_ADMISSION_WAIT_MS=3000`, matching the load test.
- Not production-verified: any real-phone journey, real invite email delivery, or a production run of the rehearsal.

### Launch holds still open

- Mel's acceptance walkthrough, and her decisions on start date, support hours, consent/retention wording and the sponsor report template. The acceptance packet has not been sent.
- Real iPhone Safari and Android Chrome checks.
- OpenRouter credit top-up and a spend cap. The account is shared with QA and had about $5 left on October 17.
- Deferred follow-ups: TransactionDraft program attribution; two narrow loan-routing phrasings in Mia; a stale card can remain for another selected year after a failed refetch.

## Built in the current code

- WorkOS/Postgres participant workspaces and cohort/admin controls.
- Annual budget years, periods, categories, allocations, confirmed actuals, and pending drafts.
- Fixed/discretionary/expected sinking-fund/unexpected sinking-fund classification.
- Text transaction capture with confirm, edit, ignore, reopen, and audit-safe actuals.
- Private S3 document imports for budgets, receipts, screenshots, statements, spreadsheets, and pay stubs.
- Receipt/statement extraction, split drafts, month assignment, matching/deduplication, and merchant/category learning.
- Uncertainty-aware receipt categorization: line-item evidence takes priority over merchant guesses, unresolved splits remain visibly reviewable, and document transactions cannot be confirmed until every split has an explicit category.
- Private source preview, expiring download links, source deletion, and import deletion controls.
- Backend voice transcription with an editable transcript before send.
- Rails-approved Mia answer packets, model narration, and deterministic fallback.
- Supervised Mia action drafts for allocation/category changes, approved household numbers and goals, and effective-dated recurring or one-time income with review-before-apply.
- A chat-primary Ask Mia surface with editable example updates, before/after impact cards, stale-review rejection, and a direct escape hatch to the matching manual controls.
- Token-bounded conversation continuity and model-backed strict intent resolution.
- Effective-dated recurring income changes, zero-dollar income endings, and month-specific one-time income.
- Annual-plan look-ahead for monthly income, planned outflow, baseline surplus, upcoming spending spikes, and expected irregular-expense drivers.
- A financial cockpit on Home and Budget that separates confirmed actuals from pending review, ranks category pressure, shows Expense Stack usage, explicitly reconciles editable category plans plus required debt minimums into total money out, and visualizes all 12 months of income versus that complete planned outflow.
- A dialogue-first Home path that asks for five household essentials, then takes a newly ready participant directly to Mia with an editable starter question.
- An optional private-upload pilot path for participants who have a useful file, with explicit review-before-apply and in-app failure reporting.
- An in-app mobile tester guide and structured, authenticated feedback flow with an optional private screenshot.
- An admin-only private feedback inbox with status filtering, explicit reviewed/resolved transitions, audited status changes, and five-minute screenshot links. Feedback narrative remains separate from cohort progress.
- A privacy-bounded pilot analytics funnel for setup, Mia, upload, draft, confirmation, failure, and review-completion signals.
- Admin/cohort progress limited to invitation, sign-in, setup state, pending-review state, and a safe last-activity timestamp.

## Locally proven

- Rails model/controller/service suite.
- Frontend lint, typecheck/build, dependency audit, and source-derived design checks.
- Authenticated local participant navigation, annual budget, pending transaction review, match suggestions, and private source preview.
- Desktop, 390-pixel mobile, and 320-pixel compact-mobile rendering of the participant shell and financial cockpit without document or money-value overflow.
- Live Mia response path through the configured model.

The financial cockpit browser coverage verifies:

- Monthly expected income, planned outflow, confirmed actuals, pending review, and remaining plan capacity.
- Pending drafts remain visually and mathematically separate from confirmed actuals until approval.
- Expense Stack and category-pressure views use the selected month's plan and activity.
- The annual cash-flow chart shows all 12 months, including scheduled income changes and spending spikes.

Rendered Playwright checks cover:

- Red/readiness guidance consistency.
- Home review-first hierarchy and month/year context.
- Dynamic readiness quick prompts.
- Bounded chat rendering and lazy attachment images.
- Mobile status-card layout, horizontal overflow, and navigation affordance.
- Basic and power-user first-session paths, tester guide, and private feedback on desktop, 390-pixel mobile, and 320-pixel compact mobile.
- Admin feedback triage on desktop, 390-pixel mobile, and 320-pixel compact mobile, including private detail, status transitions, and short-lived screenshot controls.
- Admin progress visibility without participant readiness percentages or financial details.
- Explicit confirmation boundaries for transaction and Mia budget-change drafts.
- Failed receipt upload recovery without losing the upload path.

## Pilot operating boundaries

The focused pre-FinCon group can use manual entry, Mia, voice, receipts, statements, general documents, annual budgets, and supervised review without Plaid. The supported first session is:

```text
Invitation and sign-in
→ save five household essentials
→ continue directly into one real Mia conversation
→ optionally create one typed or voice transaction draft
→ review before confirming
→ test a demo-safe upload only when useful
```

After setup, Ask Mia is the fastest supported update path: participants can describe approved household-number changes, budget-plan changes, and future income changes conversationally. Mia never writes from the message alone. It prepares a typed review card, shows the before/after monthly impact, revalidates the underlying records at apply time, and preserves My Profile and Budget as complete manual alternatives.

The optional file path accepts budgets, statements, receipts, screenshots, and pay stubs through the same review-before-apply boundary. Completed imports describe the reviewable results actually produced—transactions, household setup values, or both—even when those differ from the upload slot the participant selected. A successful automated test is not enough: uploads from Ask Mia and My Profile remain unproven until exercised on the custom domain and real phones. See `docs/pilot-tester-guide.md` for participant instructions and `docs/pilot-analytics-contract.md` for the event and coach-visibility privacy contract.

Pilot feedback is stored in the participant's authenticated household scope. Its narrative and optional screenshot are never copied into PostHog or shown in the cohort progress screen. Admins review it in a separate private inbox; list responses omit narrative and storage keys, while screenshot access requires a short-lived signed link. Participants are warned not to include financial values, account information, document contents, passwords, or private Mia messages.

## Not yet production-proven

Do not mark these complete from unit tests or local browser checks alone:

- Phone receipt screenshot → extraction → review → confirm → actuals on the custom domain.
- Multi-month statement → correct periods → match/dedupe → month close on the custom domain.
- Real phone voice → editable transcript → pending draft only.
- Multi-turn Mia household, income, or budget change → review card → apply/cancel in production.
- Private preview/download/delete authorization in production.
- Participant/admin isolation using representative production accounts.
- Real iOS Safari and Android Chrome behavior.

Record production evidence against `docs/production-readiness-checklist.md` after each deploy.

## Current readiness rule

The application currently calculates readiness deterministically from monthly cash flow, protected liquid assets, and the household's saved runway target:

- Red: the household has not yet met the Yellow conditions.
- Yellow: monthly cash flow is nonnegative and protected liquid assets cover at least half of the saved runway target.
- Green: monthly cash flow is positive and protected liquid assets cover the full saved runway target.

With the default six-month runway target, Yellow begins at three months and Green begins at six months. Home shows both dollar thresholds and remaining gaps. This is the implemented pilot rule; Mrs. Mel still needs to confirm that it is the final coaching-method definition.

Optionality uses this same approved readiness status for plain-language fit guidance rather than presenting a separate, arbitrary 0–100 score. Wealth reports the current debt balance as dollars remaining; it does not display payoff progress because the product does not yet store an original payoff baseline.

## Product decisions still requiring discovery

These require product approval rather than engineering inference:

- Exact Red/Yellow/Green thresholds and whether Red always means zero discretionary safe-to-spend.
- The 20–30 representative Mia questions and examples of a good versus bad response.
- Mia Memory: what can be remembered automatically, what requires confirmation, what a coach can see, and how participants edit, forget, or pause it.
- The minimum always-on participant modules and the coach-controlled module catalog.
- Coach-persona onboarding inputs, source governance, participant disclosure, and the approval process for culturally specific language or examples.
- Whether mobile keeps all seven current tabs visible before configurable modules exist, or moves secondary modules under More.

## Next sequence

1. Production-prove chat-primary supervised household, income, and budget changes on desktop and real phones, including stale-review rejection and manual-control escape paths.
2. Give the dialogue-first tester guide to the focused four-person group and observe whether each person can reach a useful Mia exchange without being taught the tabs.
3. Continue real-device evidence for Ask Mia and My Profile uploads with supported spreadsheets and images.
4. Record production evidence for voice, statement matching, private document controls, participant/admin isolation, and in-app feedback follow-up.
5. Use those findings to define the separate FinCon coach demonstration and coach-platform foundation. Keep coach persona and configurable participant modules as the next distinct product track.
