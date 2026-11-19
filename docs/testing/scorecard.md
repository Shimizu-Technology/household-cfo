# Statement import scorecard

The scorecard measures the gap between approved Household CFO results and a family's answer key. A failed product target is a finding, not a failing build. CI fails when a metric gets worse than its committed baseline or the run crashes.

## Context and acceptance

At base commit `5fc80106e` (November 19, 2026), a participant uploads documents, reviews account ownership and source lines, and sees categorized spending in Budget and Mia's spending analysis. The API uses the durable extraction dispatch/job, the append-only source-review domain, and transaction projections. Budget sums confirmed transaction splits; the spending analyzer reads approved source rows and nets refunds. These are separate product outputs and can disagree.

Sources: [Talun fixture contract](../../api/test/fixtures/files/documents/talun-year/README.md), `FinancialDocumentExtractionJob`, `SourceReview::ParticipantPlan`, `SourceReview::LineApprover`, `SourceReview::ApprovedSourceReader`, `SpendingPatterns::Analyzer`, and `HouseholdFinance::AnnualBudgetManager`.

Acceptance for this backend task is agent-executed: replay all 79 fictional documents offline; approve through the production review services; reconcile observed results against the independent answer key; reject regressions; test external-path isolation using fictional copies; pass the Rails gate. Browser layout, mobile interaction, upload authentication/rate limiting, and production are outside this task's coverage. This does not establish browser usability acceptance.

## Run it

From `api/`, with Ruby 3.3.7, the installed bundle, local PostgreSQL, and Poppler available:

```sh
RAILS_ENV=test DATABASE_TEST_NAME=household_cfo_test_t4 bin/rails db:prepare
RAILS_ENV=test DATABASE_TEST_NAME=household_cfo_test_t4 bin/rails scorecard:run FAMILY=talun-year RATCHET=1
```

The command prints a monthly table and aggregate-only JSON to stdout. It creates a fresh participant/household inside a transaction, uploads actual fixture bytes to `STORAGE_BACKEND=local`, requests the real extraction dispatch, executes the extraction job synchronously, and then rolls back all records. Its temporary storage directory is outside the checkout and is removed on success or failure. The test DB is required; production execution is refused. Do not point `DATABASE_URL` at another environment.

The clock is fixed to the day after the answer key's end date. Otherwise December's fictional transactions would change from future to past as CI ages. PostgreSQL JIT is disabled within the transaction. The runner also refreshes planner statistics for its growing fixture ledger: uncommitted rows are invisible to autovacuum. Neither changes the SQL's accounting results.

Normal Minitest runs a seven-document subset covering statement review, Apple Cash, both identical coffee purchases, pending/posted screenshot overlaps, cash withdrawals, and a voucher receipt:

```sh
DATABASE_TEST_NAME=household_cfo_test_t4 PARALLEL_WORKERS=4 bin/rails test test/services/scorecard_test.rb
RAILS_ENV=test DATABASE_TEST_NAME=household_cfo_test_t4 bin/rails scorecard:run SAMPLE=1 RATCHET=1
```

The subset's expected amounts are independently selected from manifest events represented by those documents. It does not compare seven documents against a full year's expected spending. The full-year command additionally covers the 298-row multi-account CSV and all receipt/transfer/refund scenarios. Run the full year before updating either baseline:

```sh
DATABASE_TEST_NAME=household_cfo_test_t4 PARALLEL_WORKERS=1 SCORECARD_FULL=1 bin/rails test test/services/scorecard_test.rb
```

## Baseline findings (November 19, 2026)

The full year took 184 seconds locally. The seven-document subset took 13.2 seconds when run alone (concurrent full-year activity made a separate run slower).

| Target | Observed | Result |
| --- | --- | --- |
| Every monthly total within 1% | Errors 3.10%–8.83%; annual $40,857.82 versus $44,242.95 | Fail |
| Zero double counts | 1, the voucher receipt | Fail |
| Zero transfer leakage | $0 | Pass |
| Fewer than 200 annual decisions | 986 | Fail |

Income is exactly $91,263.50. Both coffee purchases survive; all 934 source rows map. Two of three receipts match their bank transactions. The voucher proposes $184.88 instead of $34.88 and, without a match, adds $184.88 alongside the bank debit. Cash-withdrawal policy omits $3,600 annually; the single-category source projection also places $240 of store cash back into Groceries. October's bank row loses the receipt's three-category allocation. March's $29.99 refund does not reduce reported spending. Budget and the analyzer happen to agree on this baseline; that agreement is not assumed by the ratchet.

The 78 recorded provider calls report 495,420 tokens and $2.98352. One interrupted exploratory request may have incurred an additional charge that is not represented in those usage records. No private source was used.

## Approval policy and decision count

The manifest supplies participant knowledge, never extraction output. The runner does not create a source row that extraction missed. Rows join to the answer key using document-local date, amount and physical locator, consuming each representation at most once. The identical coffee pair uses occurrence slots within its distinct-purchase group, rather than insisting on an unknowable individual event ID.

For typed sources, the simulator links each account to the correct household account and uses `ParticipantPlan` and `LineApprover`. It answers transfers, card payments, refunds, direction, category and duplicate questions from the key. It also counts and makes corrections a careful reader would make to visibly wrong classifications/categories. True copies and pending authorizations are left out; the opposite leg of a transfer is retained as a movement. If the production save guard reveals an additional overlap after an edit, the simulator counts that decision and uses the source proposal's normal stage/approve path to confirm genuinely distinct activity.

Each displayed line question counts once. Account identity, coverage answers, each page approval, manual corrections/exclusions, receipt confirmation/category choices/matches, and additional overlap guards also count. Counts measure answers and review actions, not keystrokes, clicks, or elapsed time. An account's CSV direction questions count per line when today's app asks them per line. Per-document overhead on multi-month documents is attributed to their first month; line answers use the event's canonical month.

Source review currently approves one category per source row. The harness does not invent split allocations or change the product's cash-withdrawal policy to make the answers pass. Legacy receipts use the real draft matcher, match accepter or confirmer. Only matches the app actually offers can be accepted. Extracted receipt tender amounts and splits remain model observations; a missing match and a full-price voucher proposal remain measurable findings. Typed receipt matches use the production source match operation.

## Metrics

All JSON money fields are integer USD cents. `error_cents = actual - expected`; percentage error uses the absolute expected amount. An expected zero with nonzero actual has a 100% error marker; the ratchet compares cents, not this marker.

- **Total/category spending:** confirmed/reconciled transaction splits, cross-checked against Budget's presenter actuals. Refund and cash behavior is whatever Budget currently implements.
- **Income:** current approved source rows classified as income, not planned recurring income. Own transfers and card payments must not contribute.
- **Analyzer spending:** the actual spending analyzer's result for each monthly window, reported separately from Budget.
- **Double counts:** counted spending/income representations beyond an economic event's capacity. The coffee group's capacity is two. A receipt added alongside its bank purchase is a double count. Legitimate receiving transfer legs are not extra spending events.
- **Transfer leakage:** approved own-account transfer/card-payment money counted as spending or income, split by those destinations. Both must be zero.
- **Receipts:** extracted versus expected new debit money, approved money counted for that event, actual bank-match status, and absolute category-allocation errors. The voucher's old balance is not new money. Receipt splits replace a bank allocation; they do not add spending.
- **Coverage:** missing manifest representations and unrecognized extracted rows. Counts are separate from financial error, so an unrelated overcount cannot conceal an omission.
- **Distinct-purchase groups:** expected and actual cardinality of indistinguishable legitimate purchases.
- **Decisions:** monthly breakdowns plus the annual total under the policy above.

Product targets are every monthly Budget total within 1%, zero double counts, zero transfer leakage, and fewer than 200 decisions per year. Income, category, receipt, analyzer and coverage errors are also ratcheted even though they have no separate headline threshold.

## Record responses once

Only the committed fictional Talun directory is eligible for recording. The recorder reads only its source bytes, uses the app's normal model/prompt and provider boundary, and commits raw provider observations. It does not turn the answer key into model responses. Native extraction still runs first; the CSV needs no provider response. Recording uses four bounded workers and rolls back each temporary household.

```sh
RAILS_ENV=test DATABASE_TEST_NAME=household_cfo_test_t4 bin/rails scorecard:record RECORD=1 \
  RECORDING_ENV_FILE=/absolute/path/to/api/.env
```

Only missing recording files are created. For a deliberate re-record, remove the selected **fictional** recording files first. The `.env` is read with `Dotenv.parse`; its key is neither printed nor committed. Do not load an entire private environment file into the shell. Before committing, inspect the new responses and verify that every name, descriptor, account and amount comes from the fictional sources. Record usage/cost in the PR. A changed source checksum or provider section label fails replay. A natively parsed statement may bypass an older recording only when none of its provider sections was consumed; a partly consumed recording still fails. A new model-dependent path without a recording fails closed; CI has no live-model fallback. The Minitest test blocks `Net::HTTP.start` as an additional network guard.

## Update a baseline after an improvement

Baselines are `talun-year/baseline.json` and `talun-year/baseline-fast.json`. Each is a complete aggregate report, not a target or an answer key. The ratchet compares each month/category's absolute cents error, income/analyzer errors, duplicate/leakage counts, receipt errors/matches, coverage, coffee cardinality, and total decisions. Improvements are allowed; one improved month cannot conceal another worse month. Decision-type breakdowns are explanatory and may change shape when the UX improves.

1. Run both modes with `RATCHET=1` against the old baselines. Investigate every failure; do not accept a regression by regenerating the file.
2. For a verified improvement, produce fresh reports through `Scorecard::Runner.new.call` and `Scorecard::Runner.new(document_paths: Scorecard::Runner::FAST_PATHS).call`. Write `JSON.pretty_generate(report) + "\n"` to the corresponding baseline files using `bin/rails runner` in **fictional mode only**.
3. Review the diff and explain the improvement. Keep unrelated metrics at least as good. Run the scorecard tests and full Rails gate, and commit the new baselines with the behavior change.

Changing metric definitions, approval policy, fixture schema or subset membership requires an explicit baseline migration review. It must not silently pass as a product improvement.

## Private interface

No real statements are included or required for this PR. Use external files implementing the same answer-key schema, with source paths relative to `FAMILY_DIR`, source checksums, expected months and offline recordings in `FAMILY_DIR/recorded_responses/`:

```sh
RAILS_ENV=test DATABASE_TEST_NAME=household_cfo_test_private bin/rails scorecard:run PRIVATE=1 \
  FAMILY_DIR=/absolute/external/family-directory \
  ANSWER_KEY=/absolute/external/answer-key.json
```

Both paths must resolve outside the checkout. Private mode is replay-only; it cannot record, update a baseline, or write an output file. It suppresses Rails, Active Record and job logging during the run, prints aggregate numbers only, and replaces failure details with a generic message so paths or descriptors cannot enter the console. Do not redirect private output into the repository. Preparing private recordings is a separate operator responsibility; this interface does not discover, inspect or upload private statements. The scorecard transaction and temporary storage are cleaned in either mode. Drop only your own test database and its parallel copies afterwards; never stop shared PostgreSQL.
