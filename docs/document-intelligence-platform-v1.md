# Document Intelligence Platform v1

Updated: 2026-07-05

This is the implementation spec for the combined PR #21/#22 direction: one proper document-to-transaction platform instead of separate half-features for receipts and statements.

## Product promise

Documents are evidence. Extraction creates draft facts and draft transactions. User approval turns them into official household numbers or confirmed actuals.

Mia can help read receipts, screenshots, pay stubs, statements, and spreadsheets, but Rails/Postgres remain the source of truth. Pending extraction never changes actuals.

## Supported v1 source types

- Receipts/photos/images: JPG, PNG, WEBP, PDF.
- Statement PDFs/screenshots: PDF/images.
- Statement CSV/XLS/XLSX files.
- Budget spreadsheets and setup files.
- Pay stubs.
- DOCX/text-like financial notes.

Runtime source files are stored in private S3 only. There is no frontend AI call and no local runtime document fallback.

## Data model additions

### `transaction_draft_splits`

A pending transaction draft can now carry reviewable split lines before confirmation.

Example:

```text
Payless total: $103.42
- Groceries: $85.42
- Cigarettes: $18.00
```

The split total must equal the draft total before confirm. Splits can start without a category, but confirmation will force an active category or use the active fallback category.

### `transaction_draft_matches`

Statement/screenshot rows can propose matches against already confirmed transactions. Accepting a match marks the draft as `matched` and does not change month-to-date actuals.

### `merchant_category_rules`

Confirmed corrections teach the household useful merchant/category rules. These are structured records, not hidden chat memory.

## Extraction output contract

The extractor returns one JSON object with:

```json
{
  "document_kind": "receipt",
  "document_date": "2026-07-05",
  "period_start_on": null,
  "period_end_on": null,
  "summary": "Payless receipt with grocery and cigarette lines.",
  "confidence": "medium",
  "warnings": [],
  "items": [],
  "transaction_drafts": [
    {
      "occurred_on": "2026-07-05",
      "merchant": "Payless",
      "total_amount": 103.42,
      "source_type": "receipt",
      "category_name": "Groceries",
      "stack_key": "discretionary",
      "confidence": "medium",
      "evidence": "Receipt total and line items are visible.",
      "raw_description": "Payless receipt",
      "external_id": "receipt-total",
      "warnings": [],
      "splits": [
        { "category_name": "Groceries", "stack_key": "discretionary", "amount": 85.42, "notes": "Food items", "confidence": "medium" },
        { "category_name": "Cigarettes", "stack_key": "discretionary", "amount": 18.00, "notes": "Tobacco line", "confidence": "medium" }
      ]
    }
  ]
}
```

## Confirmation rules

- Pending drafts are never actuals.
- Confirmed drafts create `HouseholdTransaction` + `TransactionSplit` rows.
- Confirmed receipt/statement transactions keep `source_import_id` lineage.
- Matching a statement row to an existing transaction changes only the draft status; actuals do not move.
- Ignoring a draft leaves actuals unchanged.
- Reopening a confirmed/corrected draft voids the created actual by marking the `HouseholdTransaction` ignored, then returns the draft to pending review.
- Reopening a matched draft removes the accepted match and returns the draft to pending review without changing actuals.
- Categories with pending drafts still cannot archive.
- Archived categories are not valid for confirmation until restored.

## Reconciliation rules

Statement rows are staged as transaction drafts. The matcher proposes likely duplicate matches based on amount, date, merchant, and category overlap. Users can:

- confirm as a new actual,
- edit/split/category-correct before confirming,
- match to an existing confirmed transaction,
- ignore,
- reopen a resolved draft for correction when a submitted review was wrong.

## Evidence library behavior

Each import keeps:

- source preview/download/delete controls,
- extraction attempt history,
- extracted setup facts,
- extracted transaction drafts,
- match proposals,
- linked confirmed or matched outcomes.

Deleting the private source is allowed after review; deleting the import is blocked once it has applied household values or resolved transactions.

## Rails-vs-AI boundary

AI extracts/proposes only. Rails validates:

- household ownership,
- active categories,
- positive amounts,
- split totals,
- supported budget years,
- duplicate match acceptance,
- source lineage,
- final transaction creation.

## Future after v1

- More sophisticated statement table parsing and OCR model evals.
- User-facing merchant/category memory controls.
- Coach-facing reconciliation dashboard.
- Optional Python worker only if OCR/table workloads outgrow Rails jobs.
