# Savings challenge participant backend

This component persists participant approvals and projects actual money reserved during a personal 90-day challenge. It remains unavailable until the selected participant runtime resolves a valid sealed release with tool registry version 3 or later and `experience_mode: savings_challenge`. It does not publish that release or complete the pilot experience.

Enrollment requires the same accepted participant membership, a writable owner/partner household role, enabled challenge cohort configuration, and no release hold. Staff and household partners cannot read or approve another participant’s enrollment. Historical membership ID and creation time prevent removing and re-adding membership from silently restoring an old enrollment.

The cohort controls `savings_challenge_enabled` (default false), `savings_challenge_release_hold` (default true), capacity (1–30, default 30), participation policy version, and configured start date. The enrollment offer supplies the current policy version, cohort label, server local today, and prospective calendar. The enrolled calendar also supplies authoritative `local_today`. Acceptance freezes Pacific/Guam and the inclusive 90-day window beginning on the later of configured start and accepted local date. A later personal start requires explicit acceptance. Accepted seats are not automatically recycled when someone withdraws.

## HTTP contract

All paths begin `/api/v1/savings_challenge`. Authentication and selected participant cohort context use existing headers. Mutation requests require `Idempotency-Key`; bodies are flat JSON. The server supplies cohort, enrollment, and actor identity. Extra fields are rejected.

| Method/path | Body / result |
| --- | --- |
| GET base path | Enrollment, accepted plan, current projection, calendar, pending counts; before enrollment, suggested target 50000 and offer |
| POST `/enrollment` | `participation_accepted: true`, `policy_version: string`, `late_start_accepted: boolean` |
| POST `/plan_drafts` | `target_cents: positive integer or null`, `expected_plan_version_id: ID or null`, optional `reason` |
| POST `/plan_drafts/:id/approve` | `accepted: true`, `expected_draft_lock_version: integer`, `expected_plan_version_id: ID or null` |
| POST `/entry_drafts` | `signed_cents: integer`, `effective_on: YYYY-MM-DD`, `funding_source: string`, `expected_version_id: ID or null`; correction also has `entry_id`, `expected_entry_lock_version`, `reason` |
| POST `/entry_drafts/:id/approve` | `accepted: true`, `expected_draft_lock_version`, `expected_version_id: ID or null`, `expected_entry_lock_version` |
| POST `/zero_attestations` | `known_zero: true`, `cutoff_on: YYYY-MM-DD`, `expected_enrollment_lock_version: integer` |
| GET `/entries`, `/entry_versions`, `/entry_drafts`, `/plan_versions`, `/plan_drafts`, `/zero_attestations` | `{ records, next_cursor }`; optional positive ID `cursor`, integer `limit` 1–100 (default 50) |

Mutation success is HTTP 200 with `{ record, replayed, challenge }`. Repeated identical actor/context/input/key returns the same private record after current authorization. Changed identity is 409; stale versions/locks are 409; unavailable access is 403; missing private records are 404; invalid inputs are 422. Cohort selection errors retain the existing 422 response. The offer is provisional; capacity is checked again under lock at acceptance.

Amounts use exact signed integer cents, never floats or decimal strings. Targets are positive cents or null for postponement. The suggested $500 is not accepted until a plan draft is explicitly approved. A revision requires a reason. There are no generic Goal mutations and no debt or complete-budget prerequisites.

Funding values are `earned_income`, `gift`, `bonus`, `new_money_reserved`, `preexisting`, `borrowed`, `cash_advance`, `existing_internal_money`, and `withdrawal`. Contributions are nonnegative; challenge-reserve withdrawals are nonpositive and explicitly classified. The four preexisting/borrowed classifications are excluded from progress. New zero entries use explicit zero attestation; correcting an existing entry to zero remains possible.

Drafts can contain a future date within the frozen window. Approval requires an elapsed local date within that window. Future drafts never automatically become actual savings. Pending corrections preserve the prior approved head until approval. Evidence fields and currency input are rejected; persisted approved versions have server-set USD and `evidence_supported_cents: 0`, with `evidence_status: not_linked` in private responses.

## Storage and governed operations

Stable `SavingsEnrollment` and `SavingsEntry` identities point to immutable `SavingsPlanVersion` and `SavingsEntryVersion` records. Separate drafts retain the reviewed facts and base version/lock. `SavingsZeroAttestation` is immutable, cutoff-specific, and may supersede an earlier attestation for the same cutoff. It requires an elapsed challenge date and no eligible approved current heads through that cutoff. Excluded funding alone does not establish reported zero.

Registry operations version 1 are `savings.enrollment.accept`, `savings.plan.stage`, `savings.plan.approve`, `savings.entry.stage`, `savings.entry.approve`, and `savings.zero.attest`. Root release integration must add these exact contracts to its new frozen registry catalog; existing sealed catalogs are unchanged here.

Runner-created private operations declare `ACTOR_REQUIRED = true`, receive `user:` from the authenticated Runner, declare `SENSITIVE_AUDIT = true`, and implement `authorize_replay!(subject)` that raises on denial. Their generic audit/execution input and all financial snapshots are empty objects. Actor/context/request fingerprints support replay without mirroring financial facts; private idempotency keys are hashed. Legacy constructors, keys, and audit contents remain unchanged. Private approved tables retain required facts and approval metadata.

Operations lock household and writable membership, then cohort/current actor/cohort membership, then enrollment and entry/draft. Enrollment capacity and financial approvals therefore serialize. SQL guards freeze identity/calendar, scope head/base/previous pointers, reject approved updates/deletes, enforce exclusive approval sequence and current-head replacement, and defer verification that an approved version publishes its head atomically. The schema dumper preserves these functions and triggers. Migration rollback rejects any challenge data or nondefault configuration before removing schema.

`SavingsChallenge::Projection` selects the latest immutable approved version per entry at a server-selected approval sequence **before** filtering effective date. Drafts do not hide approved history, and moving a correction’s effective date later does not resurrect its older amount at an earlier cutoff. Public endpoints accept neither sequence nor reporting-knownness. Future checkpoint callers must choose cutoff and sequence server-side. The projection returns signed reported cents, the evidence subset, exact integer progress basis points, approved version IDs, and explicit unknown/zero states. Missing final attestation does not erase known earlier progress.

Source evidence allocation, source-account reconciliation, baseline approval, privacy deletion/retention policy, coach/sponsor views, checkpoints, lessons, reflections, UI, release publication, and deployment are outside this component. Enrollment currently records the accepted policy and membership epoch but does not yet pin an acceptance-time sealed release reference; real version-3 release integration must resolve that plan requirement before launch. The immutable records require a separate deliberate retention/deletion design; ordinary model deletion is rejected. Financial approval time uses the application’s server clock; SQL alone does not enforce elapsed local time or current membership authorization. All supported writes must continue through governed operations.
