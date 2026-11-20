# Statement import scorecard

The scorecard measures the gap between approved Household CFO results and a family's answer key. A failed product target is a finding, not a failing build. CI fails when a metric gets worse than its committed baseline or the run crashes.

## Context and acceptance

At base commit `5fc80106e` (November 19, 2026), a participant uploads documents, reviews account ownership and source lines, and sees categorized spending in Budget and Mia's spending analysis. The API uses the durable extraction dispatch/job, the append-only source-review domain, and transaction projections. Budget sums confirmed transaction splits; the spending analyzer reads approved source rows. Since the November 20, 2026 refund follow-up, both subtract the same approved refund credits (`HouseholdFinance::RefundCredits`): a refund reduces the category of the purchase it refunds, in the month it posts. These are still separate product outputs and are measured separately.

Sources: [Talun fixture contract](../../api/test/fixtures/files/documents/talun-year/README.md), `FinancialDocumentExtractionJob`, `SourceReview::ParticipantPlan`, `SourceReview::LineApprover`, `SourceReview::ApprovedSourceReader`, `SpendingPatterns::Analyzer`, and `HouseholdFinance::AnnualBudgetManager`.

Acceptance for this backend task is agent-executed: replay all 79 fictional documents offline; approve through the production review services; reconcile observed results against the independent answer key; reject regressions; test external-path isolation using fictional copies; pass the Rails gate. Browser layout, mobile interaction, upload authentication/rate limiting, and production are outside this task's coverage. This does not establish browser usability acceptance.

## Run it

From `api/`, with Ruby 3.3.7, the installed bundle, local PostgreSQL, and Poppler available:

```sh
RAILS_ENV=test DATABASE_TEST_NAME=household_cfo_test_t4b bin/rails db:prepare
RAILS_ENV=test DATABASE_TEST_NAME=household_cfo_test_t4b bin/rails scorecard:run FAMILY=talun-year RATCHET=1
```

The command prints corrected and question-only monthly tables and aggregate-only JSON to stdout. Each view creates a fresh participant/household inside a transaction, uploads actual fixture bytes to `STORAGE_BACKEND=local`, requests the real extraction dispatch, executes the extraction job synchronously, and then rolls back all records. Its temporary storage directory is outside the checkout and is removed on success or failure. The test DB is required; production execution is refused. Do not point `DATABASE_URL` at another environment.

The clock is fixed to the day after the answer key's end date. Otherwise December's fictional transactions would change from future to past as CI ages. PostgreSQL JIT is disabled within the transaction. The runner also refreshes planner statistics for its growing fixture ledger: uncommitted rows are invisible to autovacuum. Neither changes the SQL's accounting results.

Normal Minitest runs nine documents covering statement review, Apple Cash, both identical coffee purchases, pending/posted screenshot overlaps, cash withdrawals, a native 24-row slice of the multi-account CSV, a voucher receipt, a refund and a card payment:

```sh
DATABASE_TEST_NAME=household_cfo_test_t4b PARALLEL_WORKERS=4 bin/rails test test/services/scorecard_test.rb
RAILS_ENV=test DATABASE_TEST_NAME=household_cfo_test_t4b bin/rails scorecard:run SAMPLE=1 RATCHET=1
```

The subset's expected amounts are independently selected from manifest events represented by those document lines. For CI, the CSV is regenerated from its header and first 24 physical data rows in temporary storage after validating the full original checksum; its answer-key scope uses only those 24 lines. Both accounts remain represented. The native parser and extraction job read these real CSV bytes, with no model-response fallback. The full year always reads all 298 original rows. It does not compare a subset against a full year's expected spending. The full-year command additionally covers every month, all statements and all receipt/transfer/refund scenarios. Run the full year before updating either baseline:

```sh
DATABASE_TEST_NAME=household_cfo_test_t4b PARALLEL_WORKERS=1 SCORECARD_FULL=1 bin/rails test test/services/scorecard_test.rb
```

## Baseline findings (November 19, 2026; schema 2)

The original full 79-document run, including both independent approval views, took 397.7 seconds. The cash-withdrawal follow-up updates the baselines below without changing metrics, approval policy, recordings or fixture scope. The nine-document CI subset with a native 24-row CSV slice took 31.6 seconds in the final measurement (a separate concurrent measurement took 37.5 seconds in another owned test database). The earlier full-CSV sample took 173.2 seconds including lock contention; the slice keeps routine CI bounded. All 934 full-year source rows map; the CI slice maps all 102 rows. These are local measurements, not hosted-CI timing claims.

| Metric | Careful-user corrections | Uncorrected / answers only |
| --- | --- | --- |
| Spending (expected $44,242.95) | $44,242.95; $0.00 / 0.0000% | $46,719.52; +$2,476.57 / 5.5977% |
| Monthly absolute spending error | 0.0000%–0.9388% | 0.0000%–27.2015% |
| Income (expected $91,263.50) | $91,263.50 | $102,372.00; +$11,108.50 |
| Double counts | 0 | 96 |
| Transfer leakage (spending / income) | $0 / $0 | $0 / $0 |
| Decisions, without adding diagnostic counters | 677 | 821 |
| Accepted as proposed | 565 | 555 |
| Correction actions, including answers that edit fields | 27 | 320 |
| Manual exclusions without a duplicate question | 298 | 0 |
| Unmapped spending count / money | 0 / $0 | 0 / $0 |
| Offered receipt matches accepted | 3 of 3 | 2 of 3 |

Careful-user correction fields: type **3**, amount **1**, date **0**, category **27**, direction **0**. Several fields can change in one action. The question-only run's edits, restricted to its displayed questions, change type **233**, amount **0**, date **0**, category **220**, direction **298**. There are **298 CSV direction questions/actions in both full-year views**; the careful user excludes those already-represented lines in that one action. The question-only run additionally encounters 158 save-time overlap-guard actions. The sample has 24 direction questions/actions, 82 corrected decisions and 92 question-only decisions.

All four product targets retain their original thresholds. Every monthly total within 1%, zero double counts and zero transfer leakage pass in the careful-user view; fewer than 200 annual decisions still fails. All twelve months match exactly. March's $29.99 refund has no findable store in its descriptor, so review asks which category it goes back to; both views answer Clothing, and it reduces March Clothing (it used to leave March $29.99 high). The answer-only spending error grows because the CSV duplicates now include cash withdrawals; missing cash previously offset some duplicates. Its monthly/category/income errors and 96 doubles remain separate ratchet failures if they worsen. Budget and the spending analyzer agree on these observed totals; their outputs remain independently measured.

Both identical coffee purchases survive. The voucher still extracts $184.88 instead of $34.88, with no offered bank match at that amount. The careful user corrects it to $34.88 through the receipt form; confirming then asks "Same purchase as …?" about the $34.88 bank debit, and she matches it (November 20, 2026 follow-up; it used to be added alongside the bank debit). The answer-only view keeps $184.88, which matches nothing, so it is still added. With June's +$34.88 gone, the annual Household category shows October's −$18.00 allocation finding on its own (−$18.00 instead of +$16.88). Cash withdrawals now contribute $3,600 annually. The single-category source projection still places $240 of store cash back into Groceries; cash back is not split by this change. October's bank row loses the receipt's three-category allocation. The voucher and allocation discrepancies remain product findings.

Final recordings: **78 completed calls, 498,935 tokens, $2.945038**. An initial pass exposed volatile CombinePDF chunk timestamps and was restarted with the Runner's fixed clock. Including its 54 completed calls, this follow-up reports **132 calls, 869,140 tokens, $5.144016**. Requests in flight at interruption may have additional unmeasured charges. The original PR's earlier $2.98352 recording run is separate. All new recordings use the 15 Runner categories; none retains the old no-active-category warning. No private source was used.

The follow-up first ran both modes with `RATCHET=1` against their old baselines. The full year reported only 14 regressions: uncorrected Budget/analyzer spending-error fields for January–June and annual. The fast sample reported the same six fields for its represented January/June and annual scope. The intentional baseline override records this cash-policy change; unrelated ratcheted metrics did not regress.

## Approval policy and decision count

The manifest supplies participant knowledge, never extraction output. The runner does not create a source row that extraction missed. Rows join to the answer key using document-local date, amount and physical locator, consuming each representation at most once. The identical coffee pair uses occurrence slots within its distinct-purchase group.

Each run creates two independent rollback-only households and exercises the same production review and Budget/analyzer services:

- **Careful user:** answer questions, correct wrong type/amount/date/category/direction, and exclude duplicate/pending rows even when the app missed them. Every included proposal with a changed field increments `manual_correction` once and the relevant `corrections_by_field` counters, even when another question was already shown. Excluding a duplicate without a duplicate question increments `manual_exclusion`, including CSV rows whose displayed question was direction. Receipt confirmation corrections use the real amount/date/split form. A bank match must actually be offered by the matcher. When confirming asks "Same purchase as …?", both views answer from the answer key: the receipt's own bank line is "Same purchase" (one receipt-match action instead of a confirmation), anything else is "Different purchase".
- **Uncorrected / answers only:** answer account ownership and the questions the app asks. Confirm or reject transfer/card/refund classifications; choose direction/type/category when those are required; answer duplicate questions and save-time overlap guards. Preserve the app's amount and date. Leave unclear rows out instead of repairing them. Rows that look ready are approved as read, including unmapped rows. A receipt match is accepted only when offered; otherwise its amount/splits remain proposals, with missing categories answered so confirmation can proceed. This measures the output of this explicit question-only policy, not unattended auto-approval.

`accepted_as_proposed` counts included source lines (and unmatched legacy receipt proposals) for which every measured field already matches, with no correction or exclusion. Confirming a correct suggestion can still count as accepted. Duplicate/pending exclusions and informational rows do not contribute. Matched legacy receipts are measured by the receipt match/extraction metrics.

A line answer counts as one user action. If answering a direction question also excludes that line, it contributes one `direction` decision, plus a separate diagnostic manual-exclusion count. Diagnostic correction/exclusion counters are never added to the action total. Page approvals, account identities, coverage answers and extra save-time overlap questions count separately. Receipt matching is one action; it is not also counted as confirmation. `questions_by_kind` preserves what the app displayed; `decisions_by_kind` partitions actual actions. CSV direction questions remain per line (24 in CI; 298 in the full year) because today's bulk sign-answer service refuses multi-account sources.

Monthly line/correction counts use the canonical event's month so a bad extracted date cannot move its own repair burden. Financial output uses the actual persisted date. Per-document overhead belongs to the document's first month. Counts measure answers and review actions, not keystrokes or elapsed time. Source review still supports one category per source row; the corrected run cannot invent source splits or change product cash/refund rules.

## Metrics

All JSON money fields are integer USD cents. `error_cents = actual - expected`; percentage error uses the absolute expected amount. An expected zero with nonzero actual has a 100% error marker; the ratchet compares cents, not this marker.

- **Total/category spending:** confirmed/reconciled transaction splits less approved refund credits in their posted month, cross-checked against Budget's presenter actuals. Refund and cash behavior is whatever Budget currently implements. A refund counted twice is a double count.
- **Income:** current approved source rows classified as income, not planned recurring income. Own transfers and card payments must not contribute.
- **Analyzer spending:** the actual spending analyzer's result for each monthly window, reported separately from Budget.
- **Double counts:** mapped spending/income representations beyond an economic event's capacity. The coffee group's capacity is two. A receipt added alongside its bank purchase is a double count. Legitimate receiving transfer legs are not extra spending events.
- **Unmapped spending:** count and cents of confirmed/reconciled spending transactions with no answer-key mapping. These cannot be assigned to an economic event for duplicate analysis and are explicitly ratcheted, never treated as known unique transactions.
- **Uncorrected view:** the same monthly/annual financial, leakage, double-count, unmapped-spending and coverage measures from the independent question-only run. Both views are ratcheted.
- **Transfer leakage:** approved own-account transfer/card-payment money counted as spending or income, split by those destinations. Both must be zero.
- **Receipts:** extracted versus expected new debit money, approved money counted for that event, actual bank-match status, and absolute category-allocation errors. The voucher's old balance is not new money. Receipt splits replace a bank allocation; they do not add spending.
- **Coverage:** missing manifest representations and unrecognized extracted rows. Counts are separate from financial error, so an unrelated overcount cannot conceal an omission.
- **Distinct-purchase groups:** expected and actual cardinality of indistinguishable legitimate purchases.
- **Decisions:** monthly breakdowns plus the annual total under the policy above.

Product targets are every monthly Budget total within 1%, zero double counts, zero transfer leakage, and fewer than 200 decisions per year. Income, category, receipt, analyzer and coverage errors are also ratcheted even though they have no separate headline threshold.

## Record responses once

Only the committed fictional Talun directory is eligible for recording. The recorder reads only its source bytes, uses the app's normal model/prompt and provider boundary, and commits raw provider observations. It does not turn the answer key into model responses. Native extraction still runs first; the CSV needs no provider response. Recording uses four bounded workers and rolls back each temporary household.

```sh
RAILS_ENV=test DATABASE_TEST_NAME=household_cfo_test_t4b bin/rails scorecard:record RECORD=1 \
  RECORDING_ENV_FILE=/absolute/path/to/api/.env
```

Only missing recording files are created by default. For an explicit full refresh add `RERECORD=1`; only the committed fictional corpus can be recorded. The recorder creates exactly the Runner's 15 active categories and uses the same fixed clock. This also makes CombinePDF's generated chunk metadata deterministic, so request digests include the actual PDF bytes. The `.env` is read with `Dotenv.parse`; its key is neither printed nor committed. Do not load an entire private environment file into the shell. Before committing, inspect the new responses and verify that every name, descriptor, account and amount comes from the fictional sources. Record usage/cost in the PR. A changed source checksum, model, `PROMPT_VERSION`, provider section label or SHA-256 of the complete canonical request payload fails replay with a re-record instruction. The payload digest includes prompts, category context, provider options and inline source bytes; object key order alone is ignored. A natively parsed statement with matching source/model/prompt headers may bypass unused recorded sections only when none of its provider sections was consumed; a partly consumed recording still fails. A new model-dependent path without a recording fails closed; CI has no live-model fallback. The runner and tests block `Net::HTTP.start`, instance `start` and instance `request`, restoring all methods even after failure. There is no live fallback.

## Update a baseline after an improvement

Baselines are `talun-year/baseline.json` and `talun-year/baseline-fast.json`. Each is a complete aggregate report, not a target or an answer key. The ratchet compares each month/category's absolute cents error, income/analyzer errors, duplicate/leakage counts, receipt errors/matches, coverage, coffee cardinality, and total decisions. Improvements are allowed; one improved month cannot conceal another worse month. Monthly and annual `manual_correction`, `manual_exclusion`, correction fields and decision/question types are ratcheted independently; missing type keys mean zero, and a new type cannot trade off against another. Accepted-as-proposed must not decrease. Both corrected and uncorrected views are checked.

1. Run both modes with `RATCHET=1` against the old baselines. Investigate every failure; do not accept a regression by regenerating the file.
2. For a verified improvement, produce fresh reports through `Scorecard::Runner.new.call` and `Scorecard::Runner.new(document_paths: Scorecard::Runner::FAST_PATHS).call`. Write `JSON.pretty_generate(report) + "\n"` to the corresponding baseline files using `bin/rails runner` in **fictional mode only**, first explicitly requiring `Rails.root.join("lib/scorecard/runner")`.
3. Review the diff and explain the improvement. Keep unrelated metrics at least as good. Run the scorecard tests and full Rails gate, and commit the new baselines with the behavior change.

Changing metric definitions, approval policy, recordings, fixture schema or subset membership requires an explicit baseline migration review. It must not silently pass as a product improvement.

For pull requests, a separate `scorecard_ratchet` CI job (which the required `rails_test` check waits for) judges both committed baseline JSON files against the merge base with **the base branch's** `lib/scorecard/ratchet.rb` and `script/check_scorecard_baselines.rb`. CI checks the base commit out into `$RUNNER_TEMP` and copies only the PR's baseline files into it, so a PR can't loosen the ratchet and worsen the baselines in the same change. If the base commit has neither file, CI says so in the log and uses the PR's copies. The scorecard test inside the Rails shards also compares with the base commit's ratchet (`SCORECARD_BASE_RATCHET`). The check needs no Rails, database or model calls. Deleting a baseline, changing its shape/scope or worsening a metric fails. New baselines are allowed when none exists at the merge base. An intentional baseline migration requires a standalone PR-description line `Scorecard baseline override: <specific reason>` (at least 20 characters); CI prints the reason and every overridden metric. The override does not bypass runtime scorecard tests. Repository maintainers must review the explanation; this is an explicit audit trail, not a branch-protection change.

A PR that changes `lib/scorecard/ratchet.rb`, `script/check_scorecard_baselines.rb` or the ratchet jobs and steps in `ci.yml` (the regions between `# scorecard-ratchet:begin` and `# scorecard-ratchet:end`) also fails unless its description has a standalone line `Scorecard ratchet change: <specific reason>` (at least 20 characters). Edit the description, then re-run the job; editing it doesn't start a new run. A PR can still edit the rest of `ci.yml`, and a reviewer must read any change to it. Fully closing that gap needs a `pull_request_target` job, which runs the base branch's workflow with the base's code and a token the PR can't change, and reads the PR's baseline files through the API without checking out or running PR code. It is not built yet.

This follow-up intentionally migrates schema 1 to 2, re-records with category context, changes receipt corrections and decision accounting, and widens the subset with a CSV slice, refund and card payment. These are measurement/recording changes, not claimed product improvements.

## Injection proofs and manual full-year gate

Run the three required adversarial checks without changing committed recordings:

```sh
RAILS_ENV=test DATABASE_TEST_NAME=household_cfo_test_t4b bin/rails scorecard:prove_injections
```

The task copies four fictional sources and their recordings to a temporary directory, runs an untouched baseline, then changes two Apple Cash purchases to transfers, shifts two purchase dates one day, and disables `ParticipantPlan` duplicate classification. It asserts that each run produces nonempty `Ratchet.regressions` and prints the failing metric paths. The temp directory and both approval households are removed. The purchase injection fails type-correction/accepted-as-proposed metrics; the date injection fails date corrections; duplicate flags off fails manual exclusions and overlap-guard actions. Request digests bind the request, so deliberately changing the recorded response in this test still exercises extraction normalization and approval.

The full year is a manual pre-phase and baseline-update task, not just the fast CI subset. Run `scorecard:run FAMILY=talun-year RATCHET=1` before each pipeline phase or baseline migration, record the head/runtime/results here or in the PR, and run all three injections whenever approval policy or ratchet behavior changes. `SCORECARD_FULL=1` also selects the full year inside Minitest. No live key is used for these gates.

## Private interface

No real statements are included or required for this PR. Use external files implementing the same answer-key schema, with source paths relative to `FAMILY_DIR`, source checksums, expected months and offline recordings in `FAMILY_DIR/recorded_responses/`:

```sh
RAILS_ENV=test DATABASE_TEST_NAME=household_cfo_test_private bin/rails scorecard:run PRIVATE=1 \
  FAMILY_DIR=/absolute/external/family-directory \
  ANSWER_KEY=/absolute/external/answer-key.json
```

Both paths must resolve outside the checkout. Private mode is replay-only; it cannot record, update a baseline, or write an output file. It suppresses Rails, Active Record and job logging during the run, prints aggregate numbers only, and replaces failure details with a generic message so paths or descriptors cannot enter the console. Do not redirect private output into the repository. Preparing private recordings is a separate operator responsibility; this interface does not discover, inspect or upload private statements. The scorecard transaction and temporary storage are cleaned in either mode. Drop only your own test database and its parallel copies afterwards; never stop shared PostgreSQL.


## Follow-up QA ledger (November 19, 2026)

Execution owner: implementation agent. Environment: Ruby 3.3.7, local test-only PostgreSQL `household_cfo_test_t4b` and its four worker copies; fictional Talun files only. Entry worktree was clean on `t3/add-talun-scorecard-runner` at `a1872d3e2`; `origin/main` was initially an ancestor. During validation, PR #314 advanced main to `400af0dda`; the branch was rebased onto that commit without conflicts and the full gate was rerun. The runbook's app orientation above was refreshed against the extraction/review/Budget/analyzer code. Scope is backend affected-flow acceptance. Browser/mobile/native interaction and production deployment are not run because no user-interface behavior changes.

| Case | Action and required observable/saved outcome | Status / evidence |
| --- | --- | --- |
| Q1 | Replay the nine-document subset through production services in both approval modes; compare independent expected spending and baseline; roll back users/households/storage | Passed: nine documents / 102 extracted and mapped rows; 24 direction answers; both views |
| Q2 | Replay all 79 files in both modes and pass `FAMILY=talun-year RATCHET=1` | Passed after rebase: full-year task exits 0 and report exactly matches schema-2 baseline |
| Q3 | Mutate two purchase types, mutate two dates, disable duplicate classification; each must fail the ratchet | Passed: `scorecard:prove_injections`; type/accepted, date, exclusion/guard paths rejected |
| Q4 | Change model, prompt header or request payload; refuse replay with re-record instruction | Passed: focused model/prompt/payload tests |
| Q5 | Copy fictional inputs outside checkout; private replay retains no records/storage and prints no source path | Passed: focused private-interface tests |
| Q6 | Regenerate a worse baseline or delete it; fail cheap CI check; explicit PR migration reason permits the intentional override | Passed: isolated temporary-git test |
| Q7 | Try class HTTP start, instance start and request; block all and restore methods after exception | Passed: focused network guard test |
| Q8 | Eager-load Rails; scorecard remains unloaded; Zeitwerk passes | Passed: direct eager-load assertion and `zeitwerk:check` |

The focused safeguards/private/native batch passed 13 tests / 51 assertions. The fixture suite passed 13 tests, including deterministic source/answer-key checks. Final gate after rebase onto `400af0dda`, with final API/source code at `c8791c81e` (100 changed files): `bin/rails test` with `PARALLEL_WORKERS=4` passed **5,438 tests / 81,798 assertions**, no failures/errors/skips (834.0 seconds); `bin/rubocop` passed **1,478 files**; `bin/brakeman --no-pager` reported **zero warnings**; `bin/rails zeitwerk:check` passed; the full-year `FAMILY=talun-year RATCHET=1` task exited 0 and its report exactly matched the committed baseline. The final reporting commit changes documentation only; the baseline check is inside the existing required CI job. The HTTP guard/loader and test classes are consolidated to keep the PR within the review file limit. The CI YAML parses and the standalone baseline comparison passes against the merge base. These checks do not establish browser usability or production acceptance.

Cleanup: all task-owned processes finished; `household_cfo_test_t4b` and copies `_0` through `_4` were dropped. The lifecycle session reports no active owned resources. Shared PostgreSQL, borrowed services/devices and other worktrees remain available. The PR worktree/branch are retained for lead integration; no merge, watch or deployment was performed.
