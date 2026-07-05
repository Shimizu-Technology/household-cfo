# Post-PR #20 roadmap

Updated: 2026-07-04

This is the working checklist for what remains after PR #20 merges. It is based on Mrs. Mel's V1 feedback, the meeting notes, Greptile hardening, and the current annual budget/transaction-loop implementation.

## First: merge/deploy confidence

- [ ] Let GitHub checks and Greptile finish clean on PR #20.
- [ ] Final browser smoke on the PR preview/local real workspace:
  - [ ] cents display everywhere
  - [ ] draft confirm updates annual table, operating view, ledger, recent transactions, and report immediately
  - [ ] draft ignore leaves actuals unchanged
  - [ ] pending drafts are never counted as actuals
  - [ ] clear chat warning works; confirmed clear removes chat context
  - [ ] historical year/profile save/year switching does not desync budget view
  - [ ] category with confirmed history can archive/restore
  - [ ] category with pending drafts blocks archive
  - [ ] Mia follow-ups for family support, red/yellow plan, and transaction draft context work
- [ ] Merge PR #20.
- [ ] Deploy API/web.
- [ ] Production smoke on `https://householdcfomethod.com` with the real smoke account.

## PR #21 recommendation: chat attachments + receipt drafts

Goal: make Ask Mia support the mobile receipt/photo workflow Mrs. Mel described.

- [ ] Add first-class attachment upload from Ask Mia.
- [ ] Support mobile camera/photo/file upload where browser/device allows.
- [ ] Store every source file in private S3 through Rails.
- [ ] Extract receipt/image facts server-side into `TransactionDraft` records.
- [ ] Show review cards in chat and/or Budget review panel.
- [ ] Support correcting merchant, date, amount, category, and notes before confirm.
- [ ] Support split receipts, e.g. Payless groceries plus cigarettes.
- [ ] Create category from the review path when needed.
- [ ] Confirm only after participant approval; actuals never change from extraction alone.
- [ ] Add tests with S3/OpenRouter stubbed.

## PR #22 recommendation: statement/screenshot reconciliation

Goal: reconcile old behavior without overwriting the live transaction loop.

- [ ] Extract rows from bank/card statements and transaction screenshots.
- [ ] Map each extracted row to the correct month by transaction date.
- [ ] Stage extracted rows as drafts/reconciliation items.
- [ ] Dedupe/match against already confirmed manual/receipt transactions.
- [ ] Let user confirm, correct, ignore, or mark matched.
- [ ] Update month actuals only after confirmation.
- [ ] Add reconciliation report/status for each statement upload.

## PR #23 recommendation: Mia memory + merchant/category learning

Goal: make Mia feel continuous without treating chat as financial truth.

- [ ] Add structured `mia_memories` or equivalent table.
- [ ] Add merchant/category rules learned from user-confirmed corrections.
- [ ] Add user-facing memory controls:
  - [ ] What Mia remembers
  - [ ] Edit
  - [ ] Forget
  - [ ] Do not remember this
  - [ ] Pause personalization
- [ ] Keep raw chat separate from curated memory.
- [ ] Ask before saving sensitive memories.
- [ ] Use structured records and approved facts before memory or model inference.

## Coaching quality / model narration

Goal: keep Rails deterministic for financial truth while making Mia less robotic.

- [ ] Have Rails produce structured answer facts/plans for complex coaching cases.
- [ ] Let the model narrate those facts inside the Mia Response Contract.
- [ ] Keep hard deterministic short-circuits for safety, pending-vs-actuals, writes, and missing facts.
- [ ] Add conversation eval prompts from real Mrs. Mel testing examples.
- [ ] Track repeated-answer regressions, especially red/yellow/green plans and follow-up planning.

## Voice input

- [ ] Add microphone affordance in Ask Mia.
- [ ] Transcribe audio server-side or through an approved backend-only provider.
- [ ] Feed transcript into the same draft/review flow as typed chat.
- [ ] Never auto-confirm transactions from voice.

## White-label VERA foundation

Not required before the first Household CFO cohort is usable, but important for FinCon/founding coaches.

- [ ] Coach/program skin model.
- [ ] Brand name, logo, colors/theme.
- [ ] Persona prompt/voice configuration.
- [ ] Coach content repository.
- [ ] Optional modules, e.g. retirement calculator, biblical finance, youth finance.
- [ ] Platform-level hard boundaries remain non-overridable.

## Architecture note

Keep Rails/Postgres as the system of record. Add Python/FastAPI only when document/OCR/RAG/model-evaluation workloads clearly require it. See `docs/ai-architecture-decision.md`.
