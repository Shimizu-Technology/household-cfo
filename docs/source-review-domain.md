# Participant source review domain

This domain records what a participant approved from a statement without changing the extracted evidence or rewriting earlier spending amounts. It sits between typed extraction and a future savings baseline. It does not calculate savings, approve a baseline, expose sponsor data, or provide controller routes.

## Records and permissions

`SourceReviewHead` identifies one immutable `FinancialSourceEvent`. Its `approved_version` remains visible while a separate `SourceReviewDraft` holds a pending correction. Approval appends a `SourceReviewVersion` and advances the head. Versions retain exact signed cents, posted and authorized dates, classification, disposition, reviewed merchant, category snapshot, reason, approver, and superseded version. Raw extracted descriptions stay in separately deletable `FinancialSourceEvidence`.

`SourceAccountReviewHead` and immutable `SourceAccountIdentityVersion` map each extracted account to a participant-reviewed `SourceTrackedAccount`. This canonical identity works across statement months. The extraction account key is not a global identity. The canonical account has an explicit asset/liability basis and an optional household `Account` link. Deleting that optional link leaves approved source facts intact. Header facts and statement periods are separately versioned participant decisions.

Database constraints enforce household scope and same-head version pointers. Triggers prevent mutation/deletion of approved facts and prevent a review head from changing its source identity. Corrections append versions. Every operation prepares and executes under a household lock and checks the current actual user: participant role plus owner/partner membership. Replay authorization repeats that check and explicitly scopes the supported result model. Coach/admin roles cannot approve through these operations.

All seven operation classes inherit `ACTOR_REQUIRED = true` and `SENSITIVE_AUDIT = true`. They accept `new(household, user:)`. The integrator must register these operations and use the actor-aware Runner with minimized audit mirrors; calling a domain service directly is not a public approval API.

## Operation contracts

All monetary inputs are integer cents. Dates use `YYYY-MM-DD`. A signed negative amount is an outflow and a positive amount is an inflow, for both account bases. Liability basis reverses the balance equation, not the economic sign. All approvals require a participant reason.

| Key | Required input and result |
| --- | --- |
| `source_review.account.link` | `source_account_id`, nullable `base_version_id`, `base_lock_version`, `statement_facts`, `reason`; choose existing `tracked_account_id` or new `label`, `account_basis`, optional `account_id`. Returns an immutable account identity version. |
| `source_review.draft.stage` | `event_id`, nullable `base_version_id`, `base_lock_version`, `facts`, `reason`, optional `projection` (default `none`). Returns the pending draft; never changes approved facts or actual spending. |
| `source_review.draft.approve` | `draft_id`, `draft_lock_version`, `draft_digest`. Returns the appended approved source version. It approves exactly the pending facts and projection choice. |
| `source_review.draft.cancel` | Same draft identity/lock/digest. Cancels only the pending proposal. |
| `source_review.revision.approve` | `revision_id`, `expected_digest` from `ApprovalState`, `requested_status` (`complete` or `qualified`), `reason`, `coverage_attestation`. Returns immutable declared coverage. |
| `source_review.economic.link` | Nullable `group_id`/`base_version_id`, `base_lock_version`, `kind`, `members`, `reason`. Each member names `source_review_version_id`, `role`, `allocation_cents`. Returns an immutable group version. |
| `source_review.expense.project` | Current `version_id`, `expected_version_digest`, explicit `projection`, `reason`. Returns an immutable positive-spending projection revision. |

`facts` names the current `source_account_identity_version_id`, `disposition` (`include`, `match`, `exclude`, `informational`), `event_type`, `signed_amount_cents`, `purchase_amount_cents`, `posted_on`, optional `authorized_on`, reviewed `merchant`, explicit `budget_category_id` (nullable means deliberately uncategorized), optional reviewed `external_reference`, `overlap_disposition`, and `matched_version_id` for a match. Event types are `purchase`, `fee`, `refund`, `income`, `transfer`, `debt_payment`, `cash_withdrawal`, `interest`, `adjustment`, and `unknown`.

Posted include/match decisions require a known nonzero amount, valid date within a reviewed period when declared, and resolved type. Informational rows have no posted monetary amount. Excluded rows remain represented and retain the participant decision. Unknown extracted rows can be corrected into complete posted facts or explicitly reviewed as excluded/informational; they cannot silently become purchases.

`statement_facts` contains period start/end, opening/closing balance cents, printed debit/credit cents, optional printed row count and its `posted`/`all` basis. Coverage attestation explicitly declares `all_document_rows_accounted` and one entry per source account: `source_account_id`, current `identity_version_id`, declared period start/end, `all_rows_accounted`.

## Overlap and economic links

A verified file checksum plus physical row locator, or a participant-reviewed external reference on the same canonical account, can identify strong overlap. Date and amount alone are ambiguous. Repeated genuine rows at distinct locators in one file survive. Pending duplicate copies require an explicit `canonical` choice; once one is approved, the other must match or be excluded. A matching alias references the exact current included version with the same account, signed amount, full purchase amount, posted date, and type. Changing the canonical target makes the alias dependency stale.

Economic links require current approved included versions. A `transfer` uses `movement` roles with opposing equal allocations on distinct canonical accounts. A `purchase_funding` link has one `purchase` role and negative `funding` transfer legs on distinct accounts; allocations equal the full purchase amount. A `refund` links one `original_purchase` allocation to one equal positive `refund` allocation. Allocations cannot exceed reviewed movement/purchase amounts or existing allocations. Member correction or account remapping makes the group ineligible until reviewed again.

Links do not automatically create expenses or savings. A wallet purchase may have a local account flow smaller than its full purchase amount. That full consumption becomes eligible only after a reviewed funding link. Its positive spending projection then uses a separate `source_review.expense.project` confirmation.

## Explicit spending projection

The projection is `none`, `create`, `replace`, or `void`. Replace/void require the exact prior `transaction_id` and its `ProjectionCorrector.snapshot_digest` as `expected_digest`. Only replace/void may name an existing transaction. The prior transaction must belong to the same source event and remain confirmed/reconciled.

Create/replace admit included negative purchase/fee/interest facts with a specific active category and supported budget date. They create a new positive `HouseholdTransaction` and split. Replace/void mark the old transaction ignored while retaining its original positive amount, date, and splits. Each approved source version can receive only one financial projection. Further changes require an appended source version. Refunds, income, transfers, debt payments, matched aliases, and informational/excluded rows never automatically become positive expenses.

The integrator must guard the legacy typed `transaction.draft.confirm` path so it cannot bypass this source approval domain. Ordinary legacy imports must retain their existing behavior through an explicit compatibility boundary.

## Coverage and baseline reader

`FinancialDocuments::SourceReview::ApprovalState.new(household, revision).call` supplies the exact content digest, current row/account version IDs, dependency references, represented/approved row counts, pending correction count, reviewed reconciliation, and deficiencies. Arithmetic agreement never means participant approval. Complete coverage requires all rows/accounts reviewed, declared periods and all-row attestations, known processed page/sheet coverage, exact reported census when supplied, and balanced reviewed header arithmetic. Incomplete sources may receive qualified coverage with explicit deficiencies. An empty monetary history remains qualified in this version.

`ApprovedSourceReader.new(household).call(revision_ids: [...])` returns:

- `rows`: current approved versions from requested revisions; pending drafts do not hide them.
- `canonical_rows`: included facts plus deduplicated current included targets of valid matching aliases. Stale identities/targets are not silently promoted.
- `requested_revision_ids`, `dependency_revision_ids`, and `revisions`: requested sources plus canonical/funding dependencies, each with current coverage digest, immutable approval ID, `complete`/`qualified`/`stale`/`unreviewed` status, participant-approved flag, full state, latest extraction revision ID, and source availability.
- `economic_groups`: valid current groups relevant to the selected canonical facts, with exact version/member allocations.
- `digest`: version, identity, coverage, and economic-link identity suitable for preparing a baseline request.

Rows include exact signed/full-purchase amounts, dates, reviewed merchant/category, canonical account and identity version, identity-current flag, `spending_eligible`, and `requires_funding_link`. Baseline consumers must deliberately handle every dependency revision's declared coverage and deficiencies. They must not assume that a qualified approval is complete, that a transfer is consumption, or that spending reduction is saved cash. The reader is private participant/domain data; a coach or sponsor endpoint needs its own permission and minimized serializer.

Coverage approvals snapshot row IDs, account identity IDs, matching target state, and economic links. Later source/account corrections and link changes invalidate their content digest and mark affected imports for renewed review. Pending correction proposals leave the approved view and its prior coverage visible. Deleting raw evidence does not erase approved financial facts; availability remains a separate truthful status.

## Validation and remaining integration

Focused tests cover immutable facts/head pointers, strict amounts/dates, permissions at prepare/execute/replay, stale drafts, atomic rollback, canonical accounts and optional link deletion, pending/approved overlaps, genuine repeated charges, match dependency corrections, refunds/transfers, split funding, explicit actual replacement/void, and complete/qualified coverage.

```sh
cd api
PATH=/Users/leonshimizu/.rbenv/versions/3.3.7/bin:$PATH RAILS_ENV=test DATABASE_TEST_NAME=bog_source_review_domain_test PARALLEL_WORKERS=1 bin/rails test test/services/financial_documents_source_review_domain_test.rb
```

Controller routes, pagination/presenters, participant UI confirmation, operation registry contracts, actor-aware Runner integration, legacy typed-confirm guards, enrollment/baseline logic, sponsor exports, retention policy, and end-to-end tests belong to subsequent integration slices. No private statements or source-row oracle are included here.

The full backend suite after fresh schema load passed 2,242 tests / 17,213 assertions. The final reader coverage-version regression was then checked in the focused suite: 24 tests / 119 assertions. Backend RuboCop passed 836 files; the added concurrency script and final changed files also passed. The two-connection check produced exactly one approved version and active actual, one stale-blocked attempt, and one still-pending duplicate copy:

```sh
SOURCE_REVIEW_CONCURRENCY_DISPOSABLE_DATABASE=bog_source_review_domain_test \
RAILS_ENV=test DATABASE_TEST_NAME=bog_source_review_domain_test \
bin/rails runner test/scripts/source_review_concurrency.rb
```

That script commits synthetic immutable records. It only runs when explicitly given the exact disposable test database name; drop that database after the check rather than disabling financial immutability for cleanup.
