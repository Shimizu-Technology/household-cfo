# Post-PR #29 roadmap: Mia quality, voice, and memory

Updated: 2026-07-08

PR #29 merged the Document Intelligence Platform v1. The app now has the core document-to-draft-to-confirmation loop Mrs. Mel asked for: private uploads, receipt/photo/statement/spreadsheet extraction, split transaction drafts, matching/reconciliation, source lineage, review-before-apply, undo/reopen, and server-backed Mia chat with attachments.

## Current product state

### Done

- User is framed as the Household CFO; Mia is the coach/assistant.
- Clerk/Postgres real workspaces, admin/cohort management, invite flow, persisted Mia chat.
- Annual budget model: budget years, months, categories, allocations, actuals, pending drafts.
- Text transaction loop: Mia can draft spend entries; user confirms/edits/ignores before actuals change.
- Document Intelligence Platform v1:
  - private S3 source storage through Rails only,
  - extraction attempt history and safe errors,
  - reviewable profile/budget facts,
  - receipt/photo transaction drafts,
  - split receipt drafts,
  - statement/screenshot row extraction,
  - draft matching/reconciliation,
  - merchant/category learning from confirmed corrections,
  - reopen/undo for wrong submissions,
  - mobile-first review cards and import history.
- Mia chat attachments are staged before send and can process receipt screenshots into reviewable drafts.
- Rails remains the source of truth. Pending drafts never count as actuals.

### Immediate validation still needed

- Production smoke on `https://householdcfomethod.com` with the real smoke account.
- Confirm production envs: Clerk, Render CORS, S3, OpenRouter, Resend, PostHog.
- Phone receipt screenshot upload -> Mia reply -> review card -> confirm -> budget actuals update.
- Statement screenshot/file upload -> rows land in correct months -> match/dedupe works.
- Desktop/mobile Mia convergence and private source preview/download work.

## Next build priority

Mrs. Mel's strongest remaining product feedback is that the transaction loop and conversation loop are the core. Now that Rails owns the money truth, the next phase is making Mia feel like the Household CFO Method coach instead of a service-generated calculator.

Recommended order:

1. **PR #30 — Mia Coaching Quality / Model Narrator**
2. **PR #31 — Voice Input + Mia Eval Harness Foundation**
3. **PR #32 — Mia Memory MVP**

## PR #30 — Mia Coaching Quality / Model Narrator

Goal: keep Rails deterministic for financial truth, but let Mia/Claude narrate approved facts in the real persona.

### Architecture

Use a two-layer answer path:

```text
User asks question
-> Rails classifies intent and gathers approved data
-> Rails computes a structured answer packet
-> Claude narrates the packet in Mia's persona
-> Rails falls back to the deterministic answer if model narration fails
```

### Non-negotiables

- Rails still owns calculations, writes, validations, actuals, pending drafts, matching, and source lineage.
- Claude may explain/coach/narrate, but must not invent facts, categories, balances, merchants, dates, due dates, or transactions.
- Pending drafts stay visibly separate from confirmed actuals.
- Validation errors, crisis/safety responses, auth errors, and confirmation writes remain deterministic.
- No frontend AI calls; OpenRouter/Claude stays backend-only.

### Implementation scope

- Add a backend Mia narrator service.
- Build structured answer packets for:
  - safe-to-spend / readiness / debt-vs-savings coaching,
  - budget questions,
  - spending reports,
  - pending draft / transaction lookup answers,
  - transaction draft presentation.
- Inject the Mia persona and response contract into narration calls.
- Add sanitation/guardrails for banned openers and false write claims.
- Add tests proving fallback behavior and prompt/packet guardrails.

### Acceptance criteria

- With OpenRouter unavailable, deterministic responses still work.
- With narration enabled, Mia replies in 3-5 plain-text sentences, direct and culturally grounded.
- Mia preserves Rails facts and clearly separates planned, actual, and pending values.
- Mia does not say a transaction was added/recorded unless Rails already confirmed it.
- Generic opener such as `That's a good question` does not appear.

## PR #31 — Voice Input + Mia Eval Harness Foundation

Goal: mobile users can talk to Mia and land in the same safe review-before-apply flow, while real-world prompts protect Mia behavior from regressions.

Scope:

- Add microphone affordance in Ask Mia.
- Capture audio in the browser with clear recording state.
- Upload audio to Rails.
- Transcribe server-side through backend-only Groq Whisper credentials.
- Feed transcript into the same Mia message / transaction draft path as typed chat.
- Never auto-confirm transactions from voice.
- Add `HouseholdFinance::MiaEvalHarness` and `api/test/evals/mia_eval_cases.yml` for practical regression prompts.

Acceptance criteria:

- User can say: `I spent twenty five at McDonald's today.`
- Transcript is visible/editable before send.
- Mia drafts the transaction for review; actuals do not change until confirm.
- Failed transcription gives a useful retry message and does not create bad records.
- Eval cases cover concert tickets, spending reports, June follow-up, manual spend draft, ignore/count-as-actuals guardrails, budget status, job transition, bill overwhelm, and pending drafts.

## PR #32 — Mia Memory MVP

Goal: Mia feels continuous and personal without treating raw chat as financial truth.

Scope:

- Add structured `mia_memories` / `household_memories` table.
- Memory categories: goal, preference, constraint, habit, coaching_style, follow_up.
- Statuses: inferred, user_confirmed, coach_confirmed, rejected, expired.
- User-facing UI: `What Mia remembers`.
- Controls: edit, forget, do not remember this, pause personalization.
- Ask before saving sensitive memories.
- Include confirmed, relevant memories in Mia context.

Acceptance criteria:

- User can inspect and remove memories.
- Mia can remember low-risk preferences like Friday check-ins.
- Mia asks before saving sensitive goals/constraints.
- Raw chat stays separate from curated memory.

## Later / FinCon foundation

- Coach/program skin model: logo, colors, theme, assistant persona, content repository.
- Optional modules: retirement calculator, biblical finance, youth finance, etc.
- Coach/admin intelligence dashboard.
- Pricing/subscription foundation.

## Production rule

Do not add new financial write paths that bypass review. Mia can propose; Rails validates; the Household CFO confirms.
