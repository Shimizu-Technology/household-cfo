# Mrs. Mel V1 Feedback & Household CFO Implementation Plan

**Date:** 2026-06-30
**Product:** Household CFO Method powered by VERA
**Status:** implementation guide with PR #20 status update

## Source notes reviewed

This plan is based on Mrs. Mel's V1 feedback and the existing project context:

- Brain-Dump: `work/shimizu-tech/Mel-Mendiola-ASC-Trust/25) Next meeting with Mrs. Mel about feedback from v1 Household CFO.md`
- Brain-Dump: `work/shimizu-tech/Mel-Mendiola-ASC-Trust/26) From Mrs. Mel - Leon Meeting — Developer Feedback.md`
- Private project source: `docs/HouseholdCFO/Mia-Persona-Brief.docx`
- Brain-Dump: `work/shimizu-tech/Mel-Mendiola-ASC-Trust/23) Mia Memory and self-learning coaching vision - 2026-06-23.md`
- Existing repo docs:
  - `docs/private-document-imports-and-mia-context.md`
  - `docs/real-mode-build-plan.md`
  - `docs/mia-persona-template.md`
  - `docs/ai-architecture-decision.md`
  - `docs/post-pr20-roadmap.md`

This document intentionally summarizes product/technical direction without copying private meeting transcript details or real user financial data.

---

## Status update after PR #31

PR #29, PR #30, and PR #31 completed the biggest remaining V1 feedback foundations:

- Document Intelligence Platform v1: receipt/photo/statement/spreadsheet extraction, transaction drafts, split drafts, matching/reconciliation, source lineage, reopen/undo, and merchant/category learning.
- Mia Coaching Quality / Model Narrator: Rails-approved answer packets, model narration, guardrails, and deterministic fallback.
- Voice Input + Mia Eval Harness: backend-only OpenRouter STT, editable transcripts before send, no auto-confirm, and YAML-backed regression prompts.

The next direction is documented in:

```text
docs/post-pr29-roadmap.md
docs/mia-memory-and-supervised-actions.md
```

Working sequence:

1. Production smoke the merged document/transaction/voice loop.
2. Add supervised Mia action drafts so Mia can propose budget/category edits for review before Rails applies them.
3. Discuss Mia Memory with Mrs. Mel, then build a visible/user-controlled Memory MVP.
4. Polish the annual budget UX and pilot-ready review flows.

The product boundary remains unchanged: Mia proposes and coaches; Rails validates and writes; the Household CFO confirms.

---

## Current status after PR #20 work

PR #20 now covers most of the planned **PR 2 — Annual budget + transaction loop foundation** scope and several earlier demo-confidence blockers.

### Done or substantially done

- Product framing: the user is the Household CFO; Mia is the coach/assistant.
- Mia persona/response contract: Section 7 seed is loaded, safety boundaries stay above persona, and tests cover banned copy/contract behavior.
- Real workspace foundation: Clerk/Postgres households, persisted Mia chat, admin/cohort management, invites, private S3 document import foundation, analytics/SEO/PWA readiness.
- Annual budget foundation: `BudgetYear`, `BudgetPeriod`, `BudgetCategory`, `BudgetAllocation`, year/month UI, direct category/allocation editing, save/cancel guardrails.
- Transaction loop foundation: `TransactionDraft`, `HouseholdTransaction`, `TransactionSplit`, Mia text-based transaction drafting, confirm/ignore, corrected status, row locks, cents preservation, and immediate actual/report refresh.
- Category management: create, rename, reclassify, archive/restore, historical actuals preserved, pending drafts block archive.
- Budget/report truth: planned vs confirmed actuals vs pending drafts are separate, pending drafts never count as actuals, ledger/report views exist.
- Conversation continuity: same signed-in user gets compacted active/open topics across long chats and devices; clear chat also clears that context after confirmation.
- Greptile hardening: fixed duplicate-confirm races, year scoping, stale budget view paths, schema drift, archived-category pending drafts, missing-period repair, and other review findings.

### Still needed before calling Mrs. Mel's feedback fully satisfied

The detailed post-merge checklist lives in `docs/post-pr20-roadmap.md`. In short, the remaining product work is:

- Final browser smoke on the PR branch, then production deploy smoke on `householdcfomethod.com`.
- Chat attachment flow for receipts/photos/screenshots.
- Receipt extraction into editable transaction drafts, including split-category receipts such as groceries plus cigarettes.
- Statement/screenshot transaction extraction and month-by-month reconciliation.
- Dedupe/match logic between manually logged transactions and later statement uploads.
- Merchant/category rules learned from user-confirmed corrections.
- Structured Mia memory UI: what Mia remembers, edit, forget, do not remember this.
- Voice/audio input for mobile-friendly transaction capture.
- Better model-narrated coaching for complex plans while Rails continues to compute financial truth.
- White-label coach/admin customization: logo, colors, persona, content repository, and module configuration.

### Architecture decision

Keep Rails as the source-of-truth backend for the cohort MVP. Add Python/FastAPI only later if document/OCR/RAG/model-evaluation workloads clearly need it. See `docs/ai-architecture-decision.md`.

---

## Product reframing from Mrs. Mel

The most important feedback is not a small UI tweak. It changes the product center of gravity.

### Correct product frame

- **The user is the Household CFO.**
- **Mia is not the CFO.**
- **Mia is the AI coach / assistant who helps the user act like the CFO.**
- **VERA is infrastructure. Household CFO Method is the first branded skin.**

Current app copy that implies “Mia is your household CFO” must be audited and replaced.

Better framing examples:

```text
You are the Household CFO. Mia helps you run the numbers.
```

```text
Household CFO Method
Your annual household plan, coached by Mia.
```

```text
Mia is ready to help — but you make the CFO call.
```

### Core product shift

Current app behavior is mostly:

```text
Profile setup → dashboard snapshot → Mia chat → document upload applies saved facts
```

Mrs. Mel’s intended product is:

```text
Annual household budget plan → live transaction capture → AI draft categorization → user confirmation → month-to-date tracking → statement reconciliation → Mia coaches from actual numbers and patterns
```

The transaction loop is the core product.

---

## Hard blockers before a serious demo

### 1. Persona brief must be implemented properly

Mrs. Mel specifically called out that the persona brief is not fully loaded. The Section 7 system prompt seed from `Mia-Persona-Brief.docx` should be implemented verbatim as the core Mia persona layer.

Requirements:

- Keep safety/legal/financial boundaries as the highest-priority non-overridable system prompt.
- Add Section 7 from the persona brief verbatim after safety rules.
- Preserve these live behaviors:
  - CBT-informed “4 to a 5” coaching frame.
  - Expense Stack framework.
  - Chamorro phrase rules.
  - Old-soul pop culture references: Dirty Dancing, Ghost, 90s references.
  - Plain text only.
  - 3–5 sentence replies.
  - No markdown/bullets.
  - No `par` as friend.
  - No `just` / `simply` minimizing language.
- Add tests proving these rules are present in the system prompt.
- Ban generic openers such as:

```text
That’s a good question.
```

Mia should answer directly. Chamorro phrases should not be reflexive or decorative.

### 2. Production uploads must work

Uploads are the path because Plaid is intentionally deprioritized. Mrs. Mel tried uploads in production and hit a fetch/broken path error.

Likely things to verify/fix:

- Netlify `VITE_API_BASE_URL` points to the Render API, not local.
- Render CORS allows `https://householdcfomethod.com` and the Netlify preview domain.
- Render has production S3 env configured:
  - `AWS_ACCESS_KEY_ID`
  - `AWS_SECRET_ACCESS_KEY`
  - `AWS_REGION`
  - `AWS_S3_BUCKET`
  - `AWS_S3_PREFIX`
- Rails logs show successful upload, private S3 storage, extraction job enqueue, and review status.
- Mobile upload works from camera/photos/screenshots where browser permissions allow.

### 3. Copy/UI framing must be corrected

Required copy fixes:

- Remove “Mia, your household CFO.”
- Remove “Plan, don’t gamble.” Mrs. Mel explicitly said this is not authentic voice.
- Reframe Ask Mia from “Mia leads” to “Mia coaches / assists.”
- Reduce any top banner/card that eats Ask Mia chat real estate.

---

## Core flow we need to build

### A. Chat-first transaction capture

The user should be able to open Ask Mia and type or speak:

```text
I spent $25 at McDonald’s today.
```

or:

```text
I spent $100 at Payless for groceries.
```

Mia should parse that into a **draft transaction**, not silently update the budget.

Expected confirmation:

```text
I’m reading this as $25 at McDonald’s under Dining Out for today. Want me to add it to this month?
```

User can:

- click **Confirm**
- click **Edit**
- click **Ignore**
- type a correction, e.g. “Actually that was groceries”

Only after confirmation does Rails write the official transaction and update budget actuals.

### B. Image / receipt / screenshot upload from chat

Ask Mia needs a first-class attachment flow. On mobile this should support camera/photo upload where browser/device allows.

User flow:

1. User opens Ask Mia.
2. User taps attach/camera.
3. User uploads receipt, screenshot, pay stub, or statement.
4. Rails stores the file privately.
5. AI extraction creates draft transaction(s) or draft setup facts depending on document type.
6. Mia summarizes what she found.
7. User confirms or corrects.
8. Confirmed values update budget categories / actuals.

Example response:

```text
I found Payless, $103.42, today. I’m reading $85.42 as Groceries and $18.00 as Cigarettes. Is that right?
```

### C. Budget direct-edit path

Everything Mia can help with through chat should also be editable directly in the Budget UI.

User can:

- create categories
- assign categories to Expense Stack layers
- set monthly planned amounts
- edit actual transactions
- correct categories
- create a new category during review

Mia and direct UI must use the same underlying records.

### D. Statement reconciliation

Statements and transaction screenshots are usually old behavior. They should reconcile the month, not replace the live transaction loop.

Statement flow:

1. User uploads one or more statements/screenshots.
2. AI extracts transaction rows.
3. Rails maps rows into the correct months.
4. System attempts to match/dedupe against already logged receipt/manual transactions.
5. User reviews unmatched/new/corrected rows.
6. User confirms.
7. Month actuals and variance update.

Important: if a user uploads six months of statements, June rows should land in June, May in May, etc.

### E. Evidence / uploads library

Every uploaded image/document should be visible somewhere after upload.

Possible UI:

```text
Uploads / Evidence
```

For each upload:

- filename / type
- uploaded date
- source status
- extraction status
- linked transactions or budget facts
- preview source
- download source
- delete source
- review/correction status

This gives users trust and lets them find old receipts/statements.

---

## Annual budget model

Mrs. Mel emphasized that a CFO looks at the year, not only the current month.

The Budget tab should lead with a current snapshot but expand into a year view.

### Budget behavior

- User sets baseline monthly salary once.
- Baseline propagates forward to future months until changed.
- Planned category amounts propagate forward until changed.
- A one-month override should be possible for irregular months.
- Actuals accumulate from confirmed transactions.
- Statements reconcile actuals after the fact.

### UI model

Current-month snapshot:

```text
June Snapshot
Planned: $X
Spent: $Y
Remaining: $Z
```

Expandable year view:

```text
Category       Jan   Feb   Mar   Apr   May   Jun   Jul ... Dec
Groceries      900   900   900   950   950   950   950 ...
Dining Out     300   300   300   300   250   250   250 ...
Car Reg Fund   100   100   100   100   100   100   100 ...
```

Each category should display its Expense Stack layer:

- Non-discretionary
- Discretionary
- Sinking Fund — Expected
- Sinking Fund — Unexpected

This is educational, not just accounting.

---

## Custom categories

Custom categories are a must-have.

Mrs. Mel’s example:

- Payless is usually groceries.
- But if the receipt includes cigarettes, that should be categorized separately if the user wants.

Required behavior:

- User can create `Cigarettes` as a category.
- User assigns it to an Expense Stack layer.
- Mia remembers that category exists.
- Future receipts/manual entries can map to that category.
- Mia can coach category cleanup later if the user creates too many micro-categories.

Example coaching:

```text
You have Coffee, Tea, Boba, and Starbucks as separate categories. That may be too much detail for this stage. Want to combine them into Coffee & Treats?
```

---

## Data model direction

The current app has a good start with households, income sources, expense items, accounts, debts, goals, chat, and financial document imports. To support Mrs. Mel’s flow, add budget-period and transaction-level records.

### Proposed tables / concepts

#### `budget_years`

Represents an annual household budget plan.

Fields:

- household_id
- year
- status: draft / active / archived

#### `budget_periods`

Represents each month in a budget year.

Fields:

- budget_year_id
- starts_on
- ends_on
- status: open / reviewing / closed

#### `budget_categories`

User-defined categories.

Fields:

- household_id
- name
- stack_key
- active
- sort_order

#### `budget_allocations`

Planned category amounts per month.

Fields:

- budget_period_id
- budget_category_id
- planned_amount_cents
- rollover_behavior or notes
- source: manual / mia_suggested / imported

#### `transactions`

Confirmed actual transactions.

Fields:

- household_id
- budget_period_id
- occurred_on
- merchant
- description
- total_amount_cents
- source_type: manual_chat / receipt / screenshot / statement / import
- source_import_id
- status: confirmed / reconciled / ignored

#### `transaction_splits`

A single receipt/transaction can hit multiple categories.

Fields:

- transaction_id
- budget_category_id
- amount_cents
- notes

#### `transaction_drafts`

AI-extracted or chat-parsed proposed transactions awaiting confirmation.

Fields:

- household_id
- source_import_id
- draft_payload_json
- status: pending / confirmed / corrected / ignored
- confidence
- warnings

#### `merchant_category_rules`

Learns useful category mappings.

Fields:

- household_id
- merchant_pattern
- budget_category_id
- confidence
- source: user_confirmed / system_inferred

#### `mia_memories`

Structured, user-visible personalization.

Fields:

- household_id
- user_id optional
- category: goal / preference / constraint / habit / coaching_style / merchant_rule / follow_up
- content
- status: inferred / user_confirmed / coach_confirmed / rejected / expired
- source_type / source_id
- visibility: user_only / coach_visible / system_only

---

## Mia context and memory

Mia should always be able to use actual user numbers. She should not guess from chat history when structured data exists.

### Context priority

For each Mia response:

1. Non-overridable safety and financial boundaries.
2. Mrs. Mel Section 7 persona prompt, verbatim.
3. Current household structured facts from the database.
4. Current budget year/month/category/transaction state.
5. Pending drafts awaiting user confirmation.
6. Relevant curated memories.
7. Recent chat history.
8. General model knowledge, used only when app data does not answer the question.

### Inspired by Hermes / OpenClaw / Honcho, but simplified

Useful external patterns:

- Hermes uses bounded `MEMORY.md` and `USER.md` files injected into the prompt, plus session search/summarization and a learning loop.
- Hermes describes a “closed learning loop”: agent-curated memory, periodic nudges, skills/playbooks, and cross-session recall.
- OpenClaw emphasizes channel-first assistant interaction, voice/media channels, session memory hooks, compaction, and bootstrap context files.
- Honcho’s memory loop is: store messages/events, reason in the background, query representations/context, inject into model calls.

Household CFO should borrow the product ideas, not the technical complexity.

Recommended Household CFO adaptation:

- Use structured Postgres memory first, not a vector database first.
- Let the user inspect/edit/delete what Mia remembers.
- Separate raw chat from curated memory.
- Ask before saving sensitive memories.
- Keep memory bounded and useful.
- Use deterministic Rails services for financial math.
- Mia explains, coaches, and proposes; Rails validates and writes.

User-facing memory controls should eventually include:

- What Mia remembers
- Edit
- Forget
- Don’t remember this
- Remember this for next time
- Pause personalization

---

## White-label coach direction

Mrs. Mel sees Household CFO as the first skin on VERA.

Future coaches should be able to customize:

- brand name
- logo
- colors/theme
- persona prompt/voice
- coaching content repository
- framework modules, e.g. retirement calculator, biblical finance, youth finance, etc.

The long-term architecture should treat:

```text
VERA = platform/infrastructure
Household CFO Method = first coach/program skin
Mia = first assistant persona
```

Hard boundaries likely stay platform-level:

- no stock picking
- no illegal/tax/legal advice beyond education
- no money movement without explicit confirmation
- no hidden use of raw financial docs in chat

---

## Recommended PR strategy

Leon prefers fewer larger PRs. Seven separate PRs is too much ceremony. Two is possible, but three is safer because this work crosses copy, AI prompting, database design, document extraction, chat UX, budget UI, and memory.

### Recommended: 3 PRs

#### PR 1 — V1 feedback blockers and demo confidence

Goal: make the existing app match Mrs. Mel’s framing and unblock production testing.

Scope:

- Copy audit: user is CFO, Mia is assistant/coach.
- Remove “Mia, your household CFO.”
- Remove “Plan, don’t gamble.”
- Reduce Ask Mia layout/banner friction.
- Implement Mia Persona Brief Section 7 verbatim, after safety prompt.
- Add tests for persona rules.
- Ban generic opener: “That’s a good question.”
- Warm neutral palette pass away from heavy green.
- Verify/fix production upload env/CORS/S3.

Why this is first:

- It gives Mrs. Mel confidence quickly.
- It does not require the full transaction data model.
- It makes the next demo feel aligned even before the deeper rebuild lands.

#### PR 2 — Annual budget + transaction loop foundation

Goal: build the core product skeleton.

Scope:

- Add budget year/month/category/allocation models.
- Add custom categories and Expense Stack layer mapping.
- Add direct Budget UI table/list with yearly expandable view.
- Add confirmed transactions and transaction splits.
- Add transaction drafts.
- Add chat text parsing for simple spend entries.
- Add confirmation UI in Ask Mia.
- Add budget actuals from confirmed transactions.
- Add upload/evidence library shell.

Example supported after this PR:

```text
User: I spent $25 at McDonald’s today.
Mia: I’m reading this as Dining Out, $25, today. Want me to add it?
User: Confirm.
Budget: Dining Out actuals increase by $25.
```

Why this PR can be large:

- The annual budget and transaction loop need the same data model.
- Splitting them too much creates temporary half-working states.
- We can still keep commits staged inside the PR.

#### PR 3 — Receipt/statement reconciliation + Mia memory

Goal: make uploads and personalization work like Mrs. Mel described.

Scope:

- Chat attachment flow for receipts/images/screenshots.
- Mobile camera/photo upload affordance.
- Receipt extraction into transaction drafts.
- Statement/screenshot extraction into transaction rows.
- Month assignment by transaction date.
- Dedupe/reconciliation against existing confirmed transactions.
- Correction loop: edit category/amount/date, then confirm.
- Merchant/category rules from user-confirmed corrections.
- Structured Mia memory MVP.
- “What Mia remembers” UI.
- Mia context builder includes annual budget, category list, transactions, pending drafts, and curated memories.

Why memory belongs here:

- Useful memory depends on categories, transactions, and corrections existing first.
- Mia should learn from confirmed behavior, not raw unapproved extraction.

### If we force 2 PRs instead

Possible but riskier:

#### PR 1 — Demo blockers + annual budget foundation

Includes PR 1 plus budget year/category/allocation foundation.

#### PR 2 — Transaction loop + uploads + reconciliation + memory

Large end-to-end feature PR.

Risk:

- PR 2 becomes very large and harder to review/test.
- More chances of shipping a half-working transaction/reconciliation flow.

### Recommendation

Use **3 PRs**.

They are still large enough to avoid seven tiny PRs, but small enough to keep each one coherent:

1. Alignment/demo confidence.
2. Core budget/transaction data model.
3. Upload reconciliation and memory intelligence.

---

## Acceptance criteria for the rebuilt core

A user should be able to:

1. Open Household CFO Method and understand that **they** are the CFO.
2. Ask Mia for help, with Mia sounding like the persona brief.
3. Create a custom annual budget category.
4. See a current-month snapshot and expandable year view.
5. Log a transaction by typing in chat.
6. Upload a receipt/image from chat.
7. Review what Mia extracted.
8. Correct category/amount/date.
9. Confirm the draft.
10. See the budget update.
11. Upload a statement later.
12. Reconcile statement rows into the correct month.
13. View all uploads/evidence.
14. Ask Mia why a category is high and get an answer from actual transactions.
15. Review/edit/forget what Mia remembers.

If these pass, the product matches Mrs. Mel’s vision much more closely than the current dashboard-first MVP.
