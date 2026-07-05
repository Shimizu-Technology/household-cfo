# Post-PR #20 roadmap

Updated: 2026-07-05

This is the working checklist for what remains after PR #20 merges. It is based on Mrs. Mel's V1 feedback, the meeting notes, Greptile hardening, and the current annual budget/transaction-loop implementation.

## First: merge/deploy confidence

- [x] Let GitHub checks and Greptile finish clean on PR #20.
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
- [x] Merge PR #20.
- [ ] Deploy API/web.
- [ ] Production smoke on `https://householdcfomethod.com` with the real smoke account.

## PR #21 recommendation: Document Intelligence Platform v1

Goal: build the full receipt/photo/statement intake and reconciliation loop as one coherent platform layer, not separate half-features.

- [ ] First-class Ask Mia attachment upload and profile/evidence upload paths.
- [ ] Private S3 source storage through Rails only.
- [ ] Server-side extraction with attempt history, warnings, confidence, and safe errors.
- [ ] Extract receipt/image facts into editable `TransactionDraft` records.
- [ ] Support split receipts, e.g. Payless groceries plus cigarettes.
- [ ] Extract rows from bank/card statements and transaction screenshots.
- [ ] Map each extracted row to the correct budget month by transaction date.
- [ ] Stage extracted rows as drafts/reconciliation items.
- [ ] Dedupe/match against already confirmed manual/receipt transactions.
- [ ] Let user edit, split, confirm, ignore, or mark matched.
- [ ] Confirm only after participant approval; pending extraction never changes actuals.
- [ ] Keep source lineage from import → draft → confirmed/matched transaction.
- [ ] Add evidence library status for extracted values, transaction drafts, and matches.
- [ ] Add tests with S3/OpenRouter stubbed.

See `docs/document-intelligence-platform-v1.md` for the implementation spec.

## PR #22 recommendation: Mia memory + merchant/category learning controls

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
