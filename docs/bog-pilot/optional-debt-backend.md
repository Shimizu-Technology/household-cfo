# Optional reviewed card terms

Participants can review optional card terms without a budget, bank connection, statement, or savings contribution. The card identity, staged draft and approved version are separate records. A pending correction leaves the approved terms in place. Approval appends an immutable version and advances its card head; stale reviews fail with HTTP 409.

This feature does not change legacy household debts, purchases, challenge entries, evidence or approval sequences. The response is an incomplete participant-owned list, not a full household portfolio. No extra-payment amount, available surplus, payoff date or savings credit is calculated.

## Terms and approval

`terms` requires `label`, `as_of_on`, `balance_cents`, `minimum_payment_cents` and `apr_bps`. The financial keys accept null for unknown values. Zero is a reviewed zero. Cents must be nonnegative JSON integers within signed bigint range; APRs must be integer basis points from 0 through 100000. For example, 1999 means 19.99%. Floating-point amounts and decimal strings are rejected.

Optional terms are `due_on`, `promotional_apr_bps`, `promotional_expires_on`, `post_promo_apr_bps`, `rate_segments` and `status`. Dates are ISO calendar dates; nullable optional fields default to null. Status defaults to `active`, and also accepts `paid_off` and `archived`. `paid_off` requires an explicit zero balance. `as_of_on` cannot be later than the enrollment's frozen Guam local today or earlier than the previous approved card version.

Each of at most eight rate segments requires `label`, `balance_cents` and `apr_bps`; nullable `promotional_expires_on` and `post_promo_apr_bps` are optional. Known segment balances cannot exceed a known card balance. A segment with missing terms remains partial. Labels are nonblank strings of at most 120 characters. Corrections require a reason of at most 500 characters. There are at most 100 card identities per enrollment; archiving retains their identity and history.

All responses contain current participant identity metadata in `actor_scope: { user_id, household_id }` and use `Cache-Control: private, no-store`. Requests require the selected `X-Cohort-Id`. Reads, writes and replay recovery require the same current participant enrollment, writable household membership, live eligible program and exact sealed tool authority. A partner's enrollment cannot read or approve another participant's cards. Staff access and release holds do not expose these records.

The V5 literal catalog adds only `savings.debt.stage` and `savings.debt.approve`, both version 1. V1–V4 remain unchanged. An older V4 program remains usable for its existing tools and cannot access these new records.

## HTTP adapter

Base path: `/api/v1/savings_challenge/debt`.

- `GET /`: qualified current comparison described below.
- `GET /records?kind=cards|drafts|versions&cursor=<id>`: ascending stable identity pages, 50 records, `{ records, next_cursor, actor_scope }`.
- `GET /source_candidates?cursor=<identity-version-id>`: the same page contract for current approved liability mappings.
- `POST /actions/stage`: requires `terms`, `expected_version_id` (nullable), and `expected_head_lock_version`. Optional fields are `card_id`, `source_mapping`, and `reason`. A new card uses null expected version and lock 0; an existing card uses its current approved version and head lock. Returns `{ record: draft, replayed, actor_scope }`.
- `POST /actions/approve`: requires `draft_id`, `accepted: true`, `expected_draft_lock_version`, `expected_version_id` (nullable), and `expected_head_lock_version`. Use the staged draft's `base_version_id` and `base_head_lock_version`; do not substitute newer heads. Returns `{ record: approved_version, replayed, actor_scope }`.
- `GET /request_status?review_action=stage|approve`: recover with the original `Idempotency-Key`. Returns `state: committed` with `record`, `replayed: true`, and actor scope; `state: unknown` with `can_retry: true` and actor scope; or HTTP 202 `state: in_flight` with actor scope when the household lock exceeds two seconds. Uncertain recovery retains only identity/action/request-key metadata client-side. Retry only the original request with its original key after status recovery.

Mutation requests require `Idempotency-Key`. The controller supplies cohort and actor; client actor, cohort, approval sequence, head assignment and knownness fields are rejected. HTTP 403 denotes unavailable participant/program/tool authority, 404 a missing own-enrollment record, 409 a stale review or conflicting request reuse, and 422 malformed input. Error responses do not return card facts.

Card records provide `id`, `savings_enrollment_id`, `lock_version`, `current_version_id`, `source_tracked_account_id`, and nested `current_version`. Draft records provide their card/enrollment identity, `terms`, `base_version_id`, `base_head_lock_version`, `lock_version`, `status`, `approved_version_id`, `reason` and source mapping fields. Approved versions provide `previous_version_id`, `version_number`, `terms`, `digest`, approving participant/time, reason and frozen source mapping fields. Version history remains immutable. Generic household audit and execution mirrors contain no card terms, cents, dates, labels, fingerprints, source snapshots or raw idempotency keys.

## Source mapping

Mapping is optional and explicit. A null or omitted `source_mapping` selects manual terms; approving such a correction clears its current mapping while preserving mapped historical versions. The UI must show that choice before approval and send either the exact selected mapping or explicit null. `source_mapping` is exactly `{ source_tracked_account_id, source_account_identity_version_id, source_revision_approval_id, fingerprint }`, obtained from a candidate. Labels never link accounts automatically. Candidates require a current approved account identity, household-owned canonical liability account, current approved revision content digest, and the latest approved statement end date for that canonical account. The draft's `as_of_on` must equal that end date. Approval rechecks all references and fingerprints under the household lock.

A candidate provides those references, `label`, `statement_as_of_on`, `fingerprint`, `snapshot`, `proposed_terms`, and `qualifications`. The snapshot freezes identity/revision digests, exact statement closing balance/date and account label. Only a nonnegative reviewed closing balance is proposed as `balance_cents`; a negative credit balance proposes null and explains that an amount owed is not established. APR and minimum remain null. Participant-entered APR, minimum, promotions and balance edits are reviewed terms, not proof that the statement printed those terms.

A later approved source correction or newer approved statement makes an old mapped card stale and removes it from current comparisons until its terms are reviewed again. Pending source/card corrections do not hide approved heads. Deleting an original document retains its approved structured facts and card history; no original file access is needed. A canonical liability can have one currently mapped card identity per participant enrollment. Cross-participant records remain private, and this mapping never allocates savings evidence.

## Qualified comparison and Mia

The summary provides `enrollment_id`, `actor_scope`, `local_today`, `cards`, `known_balance_subtotal_cents`, `unknown_balance_count`, `stale_card_count`, `snowball_order`, `avalanche_order`, and human-readable `qualifications`. `portfolio_complete` is always false. `extra_payment_cents`, `payoff_date`, and `savings_credit_cents` are always null.

Each current approved card contains `card_id`, `version_id`, `label`, canonical `terms`, `source_stale`, `qualifications`, `promotional_expired`, `snowball_eligible`, and `avalanche_eligible`. Drafts are excluded. Paid-off, archived, stale and unknown-balance cards are not targets. Known balance subtotal excludes stale and archived records, is null when none is known, and can be explicitly zero.

Snowball is ascending known positive balance, with card identity as a stable tie breaker. It remains qualified where rate or minimum is missing. Avalanche is descending known single APR among known positive balances; unknown APRs, promotional terms and separate-rate segments are excluded. Promotional expiry is shown without assuming a missing successor APR. Neither order establishes that extra money is available or recommends payments.

Mia uses these current qualified records for debt questions and explains missing rates, incomplete coverage, promotions and stale sources. The explicit no-debt path remains available; missing minimum information is not treated as a no-debt claim. Card payments and balance changes remain separate from challenge savings.

## Validation and integration limits

Domain/request tests cover null versus zero, promotional/multiple rates, correction heads, source fingerprints, newer statements, retained facts after source deletion, participant isolation, release holds, role changes, older sealed V4 denial, exact pagination, recovery and minimized audits. PostgreSQL tests exercise immutable terms/drafts/heads and malformed JSON terms. Concurrent connections test competing corrections, duplicate canonical claims, identical retries and bounded status recovery.

The migration supplies fresh-schema function/trigger dumping. Its down migration locks only the three new tables and rejects any retained participant history. Integration must add optional UI and personal export wiring separately; no source-accounting parser or legacy debt-planner behavior changes in this slice.

Verified on Ruby 3.3.7 with explicit disposable PostgreSQL URLs and `PARALLEL_WORKERS=1`: full API gate 2514 tests / 39010 assertions passed; initial related focus 68 / 689 passed; actual concurrency/status-lock checks 4 / 20 passed; final role/program controller focus 6 / 47 passed; final fresh-schema domain/SQL focus 14 / 94 passed, including the subsequently added retained-history down guard regression. RuboCop inspected 1025 files without offenses; Zeitwerk passed; Brakeman reported zero errors/warnings; bundler-audit reported no vulnerabilities. The empty own migration down/up and final schema load retained all three debt triggers and the terms-validation function. No servers, browser tabs, providers or real documents were used in this slice.
