# Private Financial Document Imports & Mia Context Architecture

**Status:** planned next implementation  
**Date:** 2026-06-23  
**Product:** Household CFO Method powered by VERA

This document defines how Household CFO should handle participant uploads such as budget spreadsheets, bank/credit-card statements, pay stubs, receipts, and photos. The goal is to build the real feature properly, not a prototype-only OCR demo.

## Why this matters

Document intake is core to the VERA / Household CFO vision: users should not feel trapped in Excel or manual data entry. They should be able to upload or photograph financial documents and have Mia help turn those documents into usable household numbers.

At the same time, these files are highly sensitive. A proper implementation must protect participants from accidental exposure, AI extraction errors, stale data, and silent budget changes.

## Core product model

Architecture note: keep document AI orchestration in Rails for v1; add Python/FastAPI only if receipt/statement/OCR/RAG workloads prove they need a separate worker/service. See `docs/ai-architecture-decision.md`.

Use this mental model throughout the implementation:

> **Documents are evidence.**  
> **Extraction creates draft facts.**  
> **User approval turns draft facts into official household numbers.**  
> **Mia coaches from official household numbers plus freshness/source context.**

This means Mia should not silently mutate a participant's profile just because a model found a number in a PDF. The user should review and approve updates before they become the source of truth.

## Non-negotiable decisions

1. **Always private S3 storage**
   - Use a custom S3 service like the DPG voter platform pattern.
   - Do not use ActiveStorage.
   - Do not use local filesystem fallback for runtime uploads, even in development.
   - Tests can stub S3; actual app runtime should require private S3 configuration.

2. **No frontend AI calls**
   - OpenRouter API keys stay server-side only.
   - Browser uploads go to Rails; Rails stores/processes documents.

3. **No silent financial updates**
   - AI can propose updates.
   - Users approve, edit, or reject before the app updates saved records.

4. **Mia uses approved data by default**
   - Mia's everyday chat context should include saved household numbers and document freshness metadata.
   - Mia should not receive raw PDFs/images in every chat request.

5. **Source files remain private**
   - Source files are only accessible through authenticated API endpoints and short-lived presigned URLs when needed.
   - No public bucket objects.
   - No raw document contents in logs, chat history, localStorage, or git.

## Reference patterns from existing Shimizu apps

### Campaign Tracker

Use as the OpenRouter OCR reference:

- `api/app/services/form_scanner.rb`
  - Gemini 2.5 Flash via OpenRouter.
  - Image input as base64 `image_url`.
  - Extraction prompt with confidence values.
  - JSON parsing and partial failure behavior.
- `api/app/controllers/api/v1/scan_controller.rb`
  - Authenticated scan endpoint.
  - Returns extracted rows for review instead of auto-saving.
- `web/src/pages/admin/ScanFormPage.tsx`
  - Review-first workflow.
  - Confidence/warning display.
  - User edits before save.

### DPG Voter Platform

Use as the private file storage/background job reference:

- `api/app/services/s3_service.rb`
  - Private S3 bucket.
  - Server-side encryption.
  - Streaming downloads.
  - Presigned temporary view/download URLs.
- `GecPdfPreview`, `GecImportUpload`, `GecImportJob`
  - Status lifecycle.
  - Background processing.
  - Cleanup behavior.
  - Safe failure handling.
- `SpreadsheetParser` / import flow
  - Spreadsheet metadata parsing.
  - Review before confirm.

## User scenarios

### New user uploads a document during onboarding

1. User creates/signs into their account.
2. User uploads a pay stub, statement, spreadsheet, or receipt.
3. Rails stores the original file in private S3.
4. A background job extracts proposed values.
5. User reviews the extracted values.
6. User clicks **Apply selected**.
7. The app updates saved Household CFO records.
8. Dashboard calculations update.
9. Mia now uses those approved numbers in chat.

### User uploads a newer document later

1. User uploads a new statement or pay stub.
2. Extraction records the document date / statement period / pay period.
3. The app compares proposed values against existing approved numbers.
4. User sees proposed changes, for example:
   - New credit card balance.
   - New net pay estimate.
   - Updated spending categories.
5. User chooses what to apply.
6. New approved values become the current source of truth.
7. Old documents remain historical evidence unless deleted.

### User asks Mia while an import is pending review

Mia should be able to say something like:

> I see a statement upload is waiting for review. I won't use those numbers as official yet, but once you approve them, your dashboard and my coaching context will update.

Mia can reference that a pending import exists, but should not treat unapproved extracted numbers as authoritative.

### User asks Mia to update numbers from a document

Mia can help start or explain the workflow, but database changes should still require confirmation:

> I found a newer Visa balance in your latest statement. Want to review and apply it?

Then the app should route the user to the document review/apply UI.

## Source of truth

The source of truth should remain the existing structured household records:

- `income_sources`
- `expense_items`
- `accounts`
- `debts`
- `goals`
- `households` / `household_profiles`

Document imports should feed those records only after review.

## Proposed data model

### `financial_document_imports`

Represents one uploaded source document.

Suggested fields:

- `household_id`
- `uploaded_by_user_id`
- `document_kind`
  - `spreadsheet`
  - `statement`
  - `pay_stub`
  - `receipt`
  - `other`
- `status`
  - `uploaded`
  - `processing`
  - `needs_review`
  - `applied`
  - `partially_applied`
  - `failed`
  - `source_deleted`
- `filename`
- `content_type`
- `byte_size`
- `checksum_sha256`
- `s3_key`
- `document_date`
- `period_start_on`
- `period_end_on`
- `extracted_summary`
- `extraction_error`
- `processed_at`
- `applied_at`
- `source_deleted_at`
- `metadata` JSONB

### `financial_document_import_items`

Represents one proposed extracted value or fact.

Suggested fields:

- `financial_document_import_id`
- `target_type`
  - `income_source`
  - `expense_item`
  - `account`
  - `debt`
  - `goal`
  - `profile_note`
- `label`
- `amount_cents`
- `balance_cents`
- `payment_cents`
- `cadence`
- `source_type`
- `stack_key`
- `account_type`
- `debt_type`
- `confidence`
  - `high`
  - `medium`
  - `low`
- `evidence`
- `selected`
- `ignored`
- `applied_at`
- `applied_record_type`
- `applied_record_id`
- `metadata` JSONB

### `financial_document_import_attempts`

Immutable extraction attempt history.

Suggested fields:

- `financial_document_import_id`
- `provider`
- `model`
- `status`
  - `processing`
  - `succeeded`
  - `failed`
- `prompt_version`
- `schema_version`
- `error`
- `started_at`
- `completed_at`
- `metadata` JSONB

Metadata can store token/cost/model diagnostics when available, but should not store full raw document content.

## S3 design

Runtime uploads should always use private S3.

Required env:

```text
AWS_REGION
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_S3_BUCKET
```

Recommended optional env:

```text
AWS_S3_PREFIX=household-cfo/development
DOCUMENT_IMPORT_MAX_BYTES=10485760
OPENROUTER_EXTRACTION_MODEL=google/gemini-2.5-flash
OPENROUTER_PDF_ENGINE=mistral-ocr
```

Suggested object key format:

```text
{AWS_S3_PREFIX}/households/{household_id}/documents/{document_import_id}/source/{safe_filename}
```

Do not include user emails, names, household names, or document labels in the S3 key.

S3 service requirements:

- Upload with server-side encryption.
- Download to IO/tempfile for processing.
- Generate short-lived presigned GET URLs for authenticated view/download.
- Delete source object when user requests source deletion.
- Never make uploaded files public.

## Supported files

Initial supported file types:

- Images: `.jpg`, `.jpeg`, `.png`, `.webp`
- PDFs: `.pdf`
- Spreadsheets: `.csv`, `.xlsx`

Initial rejection list:

- `.xls` legacy spreadsheets
- archives (`.zip`, `.rar`, etc.)
- executable files
- SVG
- unsupported office formats unless explicitly added later

Recommended initial size limits:

- Images: 10 MB
- PDFs: 20 MB
- Spreadsheets: 10 MB

## Extraction strategy

### Images

Use OpenRouter chat completions with image data URLs:

```json
{
  "type": "image_url",
  "image_url": {
    "url": "data:image/jpeg;base64,..."
  }
}
```

### PDFs

Use OpenRouter file inputs:

```json
{
  "type": "file",
  "file": {
    "filename": "statement.pdf",
    "file_data": "data:application/pdf;base64,..."
  }
}
```

Use the OpenRouter file parser plugin for PDFs. Make the engine configurable:

- `mistral-ocr` for scanned/image-heavy documents.
- `cloudflare-ai` for cheaper text extraction when good enough.
- `native` only when the selected model supports native file input and it is appropriate.

### Spreadsheets

Do local parsing first with `roo`/CSV:

1. Parse sheet metadata and bounded rows server-side.
2. Detect headers/sheets.
3. Normalize rows into a compact text/JSON summary.
4. Send bounded content to OpenRouter for classification/mapping into Household CFO concepts.

This is safer and cheaper than sending an entire workbook blindly.

## Structured extraction schema

Use structured outputs where supported.

Recommended top-level extraction result:

```json
{
  "document_kind": "statement",
  "document_date": "2026-06-23",
  "period_start_on": "2026-06-01",
  "period_end_on": "2026-06-30",
  "summary": "Short participant-readable summary.",
  "confidence": "medium",
  "items": [
    {
      "target_type": "expense_item",
      "label": "Groceries",
      "amount": 825.42,
      "cadence": "monthly",
      "stack_key": "discretionary",
      "confidence": "medium",
      "evidence": "Grocery-like transactions totaled $825.42."
    }
  ],
  "warnings": [
    "Statement appears to cover only part of the month."
  ]
}
```

The service should validate model output before saving items. Unknown target types, unsupported stack keys, invalid cadences, and negative values should be rejected or converted into warnings.

## Review and apply behavior

The review UI should show extracted items grouped by household area:

- Income
- Expenses
- Accounts
- Debts
- Goals/notes
- Warnings

For each item, users should be able to:

- select/unselect
- edit label
- edit amount/balance/payment
- adjust type/category
- see confidence
- see evidence snippet
- apply selected values
- ignore bad values

Applying selected values should run through a dedicated service, not direct controller mutations.

Suggested service:

```text
HouseholdFinance::DocumentImportApplier
```

Responsibilities:

- Re-validate selected import items.
- Create or update matching records.
- Preserve lineage via `applied_record_type/id`.
- Mark items as applied.
- Mark import as `applied` or `partially_applied`.
- Return updated workspace data.

## Mia context design

Mia should get three layers of context:

### 1. Approved household numbers

This remains the main context:

- monthly income
- expense stack totals
- debt totals/payments
- assets/emergency fund
- runway
- safe-to-spend
- Optionality/CFO Filter metrics

### 2. Source/freshness metadata

Mia should know where current numbers came from and whether they may be stale:

```json
{
  "document_freshness": {
    "latest_applied_pay_stub": {
      "document_date": "2026-06-15",
      "applied_at": "2026-06-23T10:00:00Z"
    },
    "latest_applied_statement": {
      "period_end_on": "2026-06-30",
      "applied_at": "2026-07-02T10:00:00Z"
    },
    "pending_imports_count": 1
  }
}
```

Mia can use this to say:

- “Your spending numbers are based on a statement through June 30.”
- “You have one uploaded statement waiting for review.”
- “Your pay-stub data may be stale; upload a newer stub if your take-home changed.”

### 3. Recent applied import summaries

Mia can receive short summaries from recently applied imports, not raw document contents:

```json
{
  "recent_applied_document_summaries": [
    {
      "kind": "statement",
      "period": "2026-06-01 to 2026-06-30",
      "summary": "Groceries and dining were the largest flexible categories. Visa ending balance was updated."
    }
  ]
}
```

Keep this bounded, for example latest 3 applied summaries and latest 3 pending summaries.

## What Mia should not do

Mia should not:

- read every raw uploaded document on every chat request
- treat pending extraction values as official
- update saved records without explicit user confirmation
- expose S3 keys or presigned URLs in chat
- quote long raw document text
- provide licensed financial/tax/legal/accounting advice based on uploads

## Stale document behavior

Each document import should capture dates when possible:

- `document_date`
- `period_start_on`
- `period_end_on`
- upload date
- applied date

Freshness rules can be simple at first:

- Pay stub older than 90 days: stale warning.
- Statement older than 60 days: stale warning.
- Spreadsheet older than 90 days: stale warning.
- Receipts are one-off evidence, not monthly source of truth unless grouped/approved.

Mia and the UI can both surface these warnings.

## API shape

Suggested endpoints:

```text
GET    /api/v1/document_imports
POST   /api/v1/document_imports
GET    /api/v1/document_imports/:id
POST   /api/v1/document_imports/:id/reprocess
POST   /api/v1/document_imports/:id/apply
DELETE /api/v1/document_imports/:id/source
DELETE /api/v1/document_imports/:id
GET    /api/v1/document_imports/:id/source_url
PATCH  /api/v1/document_imports/:id/items/:item_id
```

Upload should use multipart form data. All endpoints must be scoped through `current_household` so participants cannot access another household's documents.

Staff/admin/coaches should follow existing household/cohort permissions before they can view participant imports.

## UI plan

### My Profile

Replace disabled upload placeholders with real upload cards:

- Budget Spreadsheet
- Bank or Credit Card Statement
- Pay Stub
- Receipt / Photo

Show:

- upload progress
- processing status
- review-needed badge
- last applied source/freshness
- source delete/reprocess controls

### Review screen/modal

Mobile-first review flow:

1. “Mia read your document” summary.
2. Warnings and confidence notes.
3. Grouped extracted items.
4. Edit/select controls.
5. Apply selected.
6. Updated dashboard confirmation.

### Ask Mia attachment

The paperclip should create a document import, not a separate direct-chat upload.

If user attaches a document in Ask Mia:

1. Upload to document import pipeline.
2. Show processing/review state.
3. Mia can say it is waiting for review.
4. After approval, Mia uses the updated official household numbers.

## Audit and privacy requirements

- Record who uploaded each document.
- Record who applied extracted values.
- Record who deleted source files.
- Avoid storing raw document text in audit logs.
- Avoid logging model prompts with document contents.
- Filter upload params from logs.
- Keep raw OpenRouter responses bounded/sanitized if stored at all.
- Do not commit uploaded test docs containing real financial data.

## Implementation plan

Target **2 PRs**.

### PR 1 — Backend foundation + extraction

Goal: private upload pipeline works end-to-end from API perspective.

Scope:

- Add `aws-sdk-s3` and `roo`.
- Add custom `S3Service`.
- Add document import models/migrations.
- Add upload/list/show/source-delete/source-url endpoints.
- Add extraction job.
- Add OpenRouter extraction service for images/PDFs/spreadsheets.
- Add extraction attempts.
- Add apply service and backend apply endpoint.
- Extend Mia context builder with approved document freshness/summary metadata.
- Add request/model/service/job tests with S3/OpenRouter stubbed.
- Update env docs.

### PR 2 — Product UI + Mia attachment integration

Goal: participant can upload, review, apply, and see Mia/dashboard update.

Scope:

- Enable upload cards in My Profile.
- Add document import review UI.
- Add status/history UI.
- Add source delete/reprocess controls.
- Add Apply selected flow.
- Wire Ask Mia attachment into same pipeline.
- Show pending import and freshness cues in Mia/UI.
- Mobile polish and accessibility.
- Frontend tests/build/lint.

### Optional one-PR compression

If speed matters, PR 1 and PR 2 can be combined into one larger feature PR, but the recommended path is 2 PRs so storage/security/extraction can be reviewed cleanly before UI polish lands.

## Acceptance criteria

The feature is ready when:

- Runtime uploads require private S3 configuration.
- Participant can upload a supported document.
- Source file lands in private S3 with encrypted object storage.
- OpenRouter extraction runs server-side only.
- Extracted values are saved as draft items.
- User can review/edit/select extracted values.
- User can apply selected values.
- Dashboard recalculates from applied records.
- Mia context uses applied values and document freshness metadata.
- Pending imports are visible but not treated as official.
- User can delete source file without deleting already-applied numbers.
- Users cannot access another household's imports or source URLs.
- Tests cover S3 success/failure, OpenRouter success/failure, apply behavior, authorization, and Mia context boundaries.
- No real statements, receipts, pay stubs, credentials, or financial documents are committed.
