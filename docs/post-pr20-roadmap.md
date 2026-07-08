# Post-PR #20 roadmap

Updated: 2026-07-08

This historical checklist tracked work after PR #20. PR #29 has now merged the Document Intelligence Platform v1, so the current forward roadmap lives in `docs/post-pr29-roadmap.md`.

This file remains as background on how the annual budget and document-intelligence work was sequenced.

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

## PR #21/#29: Document Intelligence Platform v1

Status: merged in PR #29.

Goal: build the full receipt/photo/statement intake and reconciliation loop as one coherent platform layer, not separate half-features.

- [x] First-class Ask Mia attachment upload and profile/evidence upload paths.
- [x] Private S3 source storage through Rails only.
- [x] Server-side extraction with attempt history, warnings, confidence, and safe errors.
- [x] Extract receipt/image facts into editable `TransactionDraft` records.
- [x] Support split receipts, e.g. Payless groceries plus cigarettes.
- [x] Extract rows from bank/card statements and transaction screenshots.
- [x] Map each extracted row to the correct budget month by transaction date.
- [x] Stage extracted rows as drafts/reconciliation items.
- [x] Dedupe/match against already confirmed manual/receipt transactions.
- [x] Let user edit, split, confirm, ignore, or mark matched.
- [x] Confirm only after participant approval; pending extraction never changes actuals.
- [x] Keep source lineage from import → draft → confirmed/matched transaction.
- [x] Add evidence library status for extracted values, transaction drafts, and matches.
- [x] Add tests with S3/OpenRouter stubbed.

See `docs/document-intelligence-platform-v1.md` for the implementation spec and `docs/post-pr29-roadmap.md` for current next steps.

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

Status: next active PR after PR #29. See `docs/post-pr29-roadmap.md`.

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
