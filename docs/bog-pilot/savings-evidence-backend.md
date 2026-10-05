# Reviewed savings evidence

Reviewed evidence qualifies part of an approved contribution. It never adds reported savings, creates spending or changes a monetary entry. The monetary `evidence_supported_cents = 0` database constraint remains intact; `SavingsChallenge::Projection` composes support from a separate immutable allocation history.

Each exact approved entry version has one allocation head. Attaching evidence replaces its complete proof set, with one to twenty reviewed proofs. Proof amounts are positive integer cents, sum to no more than the eligible contribution, and require explicit participant ownership and new-money-reservation acceptance. The participant must explain the review. Pending monetary corrections retain the prior approved financial head. An approved correction selects a new monetary version and does not inherit old proof.

## Domain operations for root adapters

Both version-1 operations inherit actor-required, sensitive audit behavior. Root must publish their literal tool catalog, add private HTTP adapters and provide the review UI before activation. This slice does not establish runtime availability.

`savings.evidence.attach` accepts exactly:

```json
{
  "cohort_id": 1,
  "entry_version_id": 1,
  "expected_evidence_version_id": null,
  "expected_head_lock_version": 0,
  "accepted": true,
  "participant_ownership_accepted": true,
  "new_money_reservation_accepted": true,
  "proofs": [{
    "source_review_version_id": 1,
    "expected_source_digest": "64 lowercase hex characters",
    "expected_account_identity_digest": "64 lowercase hex characters",
    "amount_cents": 5000,
    "economic_group_version_id": null,
    "expected_group_digest": null
  }],
  "reason": "Participant review explanation"
}
```

`savings.evidence.revoke` accepts `cohort_id`, `entry_version_id`, the nonnull current `expected_evidence_version_id`, `expected_head_lock_version`, `accepted: true` and `reason`. It may revoke a stale proof on an older monetary version belonging to the same participant. It appends a zero-support revision; it does not erase accepted history. Both operations return `SavingsEvidenceVersion`, support Runner idempotency and reauthorize the enrollment on replay. Generic audit and execution mirrors omit proof facts, cents, dates and explanations. Only the authorized private serializer returns those facts.

The actor is injected by Runner. IDs cannot grant access: current participant role, owner/partner household membership, frozen enrollment membership identity and an available savings release are checked again inside household/cohort/enrollment locks. Financial changes require an active enrollment, including evidence review. Client actor, support, sequence and status fields are rejected.

## Canonical capacity

A direct positive reviewed `income` movement on an asset account can qualify a reservation. A transfer requires an exact current approved two-account asset transfer group, with one positive and one negative movement and equal group allocations. Either leg identifies the same movement. Match aliases resolve their immutable approved canonical target. Refunds, card/debt payments, liability accounts, adjustments, ungrouped transfers, unknown classifications and ambiguous/multiple economic groups do not establish reserve evidence. Existing, borrowed and cash-advance funding classifications remain excluded even when a bank movement exists. Source dates must fall in the personal frozen challenge window and cannot be future posted facts.

Each proof reserves its cents against canonical source-event identities. A two-leg transfer reserves the same amount against each leg; those reservations are one evidence subset, not two contributions. The common household lock and PostgreSQL publishing guards cap active reservations across partners, enrollments and programs. Source revisions, match aliases and regrouping cannot create a new pool for the same canonical event. Same date and amount alone do not prove identity.

Stale proof continues reserving capacity until an explicit revoke or replacement. A monetary correction therefore needs the old proof revoked before the same capacity can support its new version. This prevents correction from silently making already allocated money available twice. Monetary reporting itself is participant-reported; evidence caps do not authorize summing overlapping program reports into a global personal total.

## Current and historical views

The default projection validates current source heads, account identity heads, economic group heads and the current monetary version. Any stale dependency makes that reviewed allocation set stale with zero current support until renewed review. Raw source deletion does not destroy approved facts or their canonical identity; approved proof remains usable. Source-view availability and deletion warnings belong to the source reader/UI and must still be shown honestly.

An explicit server-selected `approval_sequence` defaults to historical evidence replay. `evidence_mode: :current` requests current qualification instead. Posted dates are checked independently against the effective-date cutoff: later posted proof cannot qualify an earlier cutoff. A later evidence approval cannot appear in an earlier approval sequence, even when its source date is earlier.

Projection adds `evidence_quality`: allocation version ID, immutable digest, exact entry version ID, status (`linked`, `stale`, `revoked`) and qualified support cents. These values are private. The participant entry serializer exposes effective support, status, evidence version ID and allocation head lock; the stored monetary support remains zero. Unknown savings still remains unknown; an empty evidence history does not attest zero.

Checkpoint capture uses current quality. Approval rejects a source correction between capture and approval, even if the savings sequence did not change. Closed snapshots retain their recorded allocation IDs, digests and quality. Explicitly revised checkpoints capture the newly reviewed quality. Historical validation can replay a frozen stale zero subset without promoting it later; legacy checkpoints without evidence fields retain their original shape. Root adapters must not expose server-only projection mode, sequence or frozen-quality arguments to clients.

FIFO withdrawals continue consuming supported cents first within each lot. A supported $200 contribution, an unsupported $100 contribution and a $150 withdrawal leave $150 reported and $50 supported. Evidence promotion does not claim that lower spending caused the contribution.

## Verification scope

Tests use synthetic reviewed extraction/account/group records through the actual source-review domain, real PostgreSQL constraints and isolated concurrent connections. No real statements, storage calls, providers, browser flows or deployed catalog activation are part of this slice. Root integration and release rehearsal remain required.

Local verification on Ruby 3.3.7, PostgreSQL `bog_savings_evidence_test`, `RAILS_ENV=test`, explicit `DATABASE_URL`/`DATABASE_TEST_NAME` and `PARALLEL_WORKERS=1`: the full API suite passed 2,390 tests and 37,926 assertions with no failures, errors or skips. The focused evidence suite passed 24 tests and 122 assertions, including four concurrency tests. Fresh migration, empty-data down/up and schema-load paths passed; the schema-loaded evidence/checkpoint suite passed 35 tests and 189 assertions before the final partner and foreign-ID additions. Lint, Brakeman, cached dependency advisory check and Zeitwerk passed. The disposable database and temporary logs are removed at handoff.
