# Approved spending baselines and patterns

A baseline freezes the financial observations and choices a participant approved for a past window. It supplies spending context for a savings challenge; it never turns lower spending, a refund, a bank balance increase, or unallocated cash into savings.

`FinancialBaselineHead` belongs to one household and actual participant. `FinancialBaselineVersion` appends an immutable window, coverage status, calculation version, digest, complete snapshot, reason, approver, and prior version. Later source corrections, category changes or baseline revisions leave earlier versions available for checkpoint references. Database foreign keys enforce the household, head, superseded version and actual participant. Existing source-review SQL triggers protect the head identity and approved snapshot after migration and fresh schema loading.

## Private preview and reader

```ruby
preview = FinancialBaselines::Preview.new(household, user: actual_user).call(request)
presentation = FinancialBaselines::Preview.presentation(preview)
current = FinancialBaselines::Reader.new(household, user: actual_user).current
historical = FinancialBaselines::Reader.new(household, user: actual_user).find(version_id)
```

Every call rechecks the current actual user: participant role and owner/partner membership under the household lock. The reader also scopes baseline history to that participant. An administrator, coach, another participant or membership downgrade cannot use these methods to inspect or approve private baselines. These are domain services, not sponsor serializers or HTTP endpoints. Any future sharing or support access requires an independently authorized, minimized read path.

The preview calculates the entire window. Presentation limits the row sample to 50 and returns its limit, represented row count, and `aggregates_use_full_window: true`. Merchant, frequency, category and monthly totals retain every canonical observation, including rows beyond 100. There is no latest-100 transaction query or Plaid-only merchant aggregation.

`Reader.current` returns the approved version without rewriting it. It separately reports `needs_revision`, the current dataset digest and deficiencies. Pending source correction drafts do not change the approved dataset; their proposed values stay outside the baseline digest. Changed approved source heads, coverage approvals, account identities, economic links, actuals or category context require a fresh preview. If a current input disappears, the historical snapshot remains readable and current-input availability is qualified.

## Request contract

The request uses exact `YYYY-MM-DD` dates for `window_start_on` and `window_end_on`, with a past inclusive window of at most 366 days. It contains:

- `revision_ids`: up to 60 household extraction revisions.
- `tracked_account_ids`: the reviewed canonical accounts represented by the baseline.
- `household_scope_attested`: whether the participant explicitly declared the household account scope.
- `missing_accounts`: known missing-account descriptions. Any listed gap prevents complete coverage.
- `cash_coverage`: `complete`, `partial`, `not_used` or `unknown`, as declared by the participant.
- `category_eligibility`: one decision for each used category (nullable ID means deliberately uncategorized), with `eligible` true/false, `recurrence` (`unknown`, `recurring`, `one_off`, `seasonal`, `annual`) and `reason`.
- `actual_decisions`: optional reviewed decisions for existing active confirmed/reconciled actuals in the window. Each names `transaction_id`, `event_type`, `disposition` (`include`, `exclude`, `match`), optional `tracked_account_id` or `cash: true`, `overlap_disposition` (`new`, `distinct`, `match`) and a reason. A match names exactly one `source_review_version_id` or `matched_transaction_id`.
- `cash_allocations`: optional exact positive-cent links from an included reviewed source withdrawal to an included manual cash purchase, with `source_review_version_id`, `transaction_id`, `amount_cents` and reason. Repeated pairs and allocations beyond either amount are rejected.

The preview returns `digest`, full canonical `rows`, actual fingerprints, category decisions/current context, source/identity/economic/coverage dependencies, account intervals and missing ranges, refund allocations, cash summary, patterns, assumptions, deficiencies, and `complete_eligible`. `observed_spending_known` distinguishes absent observations from a known amount. `window_complete_calendar_month_count` describes the requested dates; `supported_complete_calendar_month_count` is zero when the dataset cannot certify the full requested coverage. A three-month date range alone is not three months of reviewed evidence.

## Approval operations

`baseline.approve` and `baseline.revise` are operation version 1, with `ACTOR_REQUIRED = true`, `SENSITIVE_AUDIT = true`, and constructor `new(household, user:)`. Both take:

```ruby
{
  request: request,
  expected_preview_digest: preview[:digest],
  base_version_id: nil, # current approved version for revise
  base_lock_version: 0, # current head lock for revise
  coverage_status: "complete", # or partial/manual
  reason: "Participant explanation"
}
```

First approval cannot overwrite an existing head; revise requires its exact current version and lock. Prepare and execute reauthorize the actual participant, recompute the preview, and reject stale fingerprints before creating a version. Replay authorizes the exact result model, household and participant again. The postcondition verifies the persisted snapshot digest against the reviewed request.

Complete coverage requires current participant-approved complete coverage for every requested/dependency source, every selected source row's current identity and funding classification, approved intervals spanning each declared account's window, explicit account/cash scope, reviewed category eligibility, and no unresolved cross-source overlaps. Known canonical accounts with overlapping reviewed periods cannot be omitted silently. Conflicting headers for the same canonical period and inconsistent adjacent closing/opening balances prevent complete coverage.

Partial and manual approvals preserve their limitations. A participant can continue without statements or a complete baseline. An empty manual baseline is approved as limited context with unknown spending observations; its calculated zero subtotal does not certify zero household spending. Excluding an active approved actual is a visible limitation and cannot certify complete spending. Duplicate evidence should instead use an explicit canonical match.

## Canonical observations and patterns

Typed spending reads current approved source heads, not extracted guesses or legacy expense drafts. Matching aliases resolve to one current canonical included version. Typed positive spending projections are omitted from the separate actual stream so they cannot repeat the same purchase. Canonical source, account identity, economic-link and declared-coverage versions are pinned. Every dependency revision, including a refund's original purchase source or a wallet funding source, receives deliberate coverage handling.

Other active manual, receipt, screenshot and Plaid actuals are read across the whole window. Manual expense records retain their approved purchase meaning. Legacy Plaid/import/statement actuals require an explicit classification before they can certify complete spending; their positive legacy amounts alone cannot prove that a transfer or card payment was a purchase. A participant can match equivalent actuals to a current canonical expense with the same full amount and posted date. Match chains/cycles are rejected. Date and amount alone across sources remain possible overlap, not proof; an explicit `distinct` decision is required to certify both.

Merchant names are normalized only for grouping, not to infer a chain, necessity, business context or optional spending. Category eligibility and recurrence are participant choices. Frequency and monthly variation are observations. A seasonal or annual purchase is never automatically extrapolated into a monthly savings opportunity. Patterns contain no suggested cut, guaranteed outcome or causal savings claim.

## Refunds, movements and cash

Reviewed refund economic links allocate the positive credit to its original purchase category/merchant. `net_spending_cents` is gross purchases less allocated refunds posted in the window. `prior_window_refunds_cents` identifies credits reversing purchases outside it. `same_window_net_spending_cents` excludes those prior-window reversals from the current purchase comparison. `comparable_eligible_spending_cents` applies that same timing rule to participant-eligible categories; consumers must use this explicit convention rather than treating a prior-period refund as a recurring spending cut. Unallocated refunds remain visible and prevent complete comparison coverage.

Transfers, debt payments and cash withdrawals have separate counts and inflow/outflow totals. They never become consumption again. A reviewed wallet funding group permits one full economic purchase despite its smaller local wallet flow; bank funding legs stay movements. Refunds and lower consumption do not create savings entries.

Cash allocation produces withdrawal, allocated-purchase and unallocated-withdrawal cents. The unallocated remainder is not saved money or proof of a standing cash balance (`cash_balance_known: false`, `savings_inferred: false`). The current allocation interface requires a reviewed source withdrawal; a manual-only withdrawal has no automatic source evidence bridge. Existing manual cash expenses still appear once in a limited manual baseline.

Asset/liability basis remains pinned for source reconciliation; consumption uses the common negative-outflow/positive-inflow sign. Closing card balances do not establish APRs, minimums or a payoff plan. The source account contract currently lacks a reviewed per-card APR/minimum/`Debt` bridge, so debt advice requires a separate reviewed record.

## Integration and validation boundaries

The root integration owns Registry/Runner registration, frozen tool-contract release versions, controllers/routes, private response serialization, UI confirmation, enrollment/accepted-plan links and checkpoint/export consumers. Generic audit mirrors must stay minimized for these sensitive operations. Enrollment/program consent must wrap household participant approval when linking a baseline to the challenge. An approved baseline cannot itself grant coach or sponsor sharing.

Request-contract and privacy behavior are tested at the domain/operation/reader boundaries here. HTTP authorization/status mapping, actor-aware Runner idempotency, challenge consent and real UI behavior require the root-owned integrated request/browser tests; no new endpoints or browser resources were added in this slice.

The S04 base conservatively qualifies histories containing only informational/zero-activity rows. A genuinely attested zero-activity card statement therefore remains partial here until source review distinguishes that case from a blank/failed document. No zero row is dropped, and no missing history is manufactured as known zero spending.

Run against an explicitly named disposable database:

```sh
cd api
DATABASE_URL=postgresql:///bog_approved_baseline_test \
DATABASE_TEST_NAME=bog_approved_baseline_test RAILS_ENV=test PARALLEL_WORKERS=1 \
bin/rails test test/services/financial_baselines_test.rb
```

`test/scripts/baseline_concurrency.rb` releases two independent database connections to approve the same first baseline simultaneously. It requires `BASELINE_CONCURRENCY_DISPOSABLE_DATABASE` to equal the exact test database name. It commits synthetic immutable records; run it after the ordinary suite and drop that owned database afterward.

The isolated backend gate passed on this slice: 2,266 tests and 17,320 assertions, with no failures, errors or skips. Rubocop inspected 848 backend files without offenses; the concurrency script passed its separate lint check. Brakeman reported no errors or warnings, and Bundler audit found no vulnerabilities. The concurrent approval check produced one approved version and one stale-blocked request, while preserving unknown spending for the empty manual baseline. These results cover the backend domain; they do not certify the root-owned HTTP, Runner, release or browser integration.
