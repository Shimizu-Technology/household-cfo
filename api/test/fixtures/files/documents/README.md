# Synthetic upload fixtures

All 25 documents are fictional test inputs, with a small **Synthetic test document** footer and no real logos. Names, payroll details, purchases, account numbers and references are invented.

`manifest.json` defines raw source rows, posted and pending totals, months, receipt category splits, budget values, pay-stub arithmetic and intentional overlaps. Amounts are integer cents. Pending rows are informational and never posted spending. Financial setup item counts exclude optional profile notes. Pay-stub proposals may be monthly normalized; compare their monthly equivalent with the printed semi-monthly net deposit.

`recorded_responses/` contains synthetic-only live extraction responses, replayed by `test/services/financial_documents_corpus_test.rb` without network access. These are model observations, not authoritative expected values; the manifest and arithmetic assertions remain independent.

Generator, pinned dependencies, regeneration command and fixture inventory: [`scripts/synthetic-documents/README.md`](../../../../../scripts/synthetic-documents/README.md).

Run offline coverage from `api/`, using your own isolated test database:

```sh
PARALLEL_WORKERS=1 bin/rails test test/services/financial_documents_corpus_test.rb
```

Do not substitute participant data. Repeated dates/amounts and `overlap_group` keys are test relationships, not permission to auto-match transactions. Account identity and overlap decisions require participant review.
