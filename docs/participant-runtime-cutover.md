# Participant runtime cutover

## Runtime selection

Each request resolves one participant runtime in this order:

1. choose one current participant membership, with an optional validated `X-Cohort-Id` selection;
2. use the newest release exposure for that exact membership ID and enrollment timestamp;
3. otherwise use the cohort's active release;
4. otherwise use the legacy persona and participant-tools configuration during deployment.

The selected release is validated before use. Mia persona, approved content, and participant tools all come from that release. If validation fails, the resolver returns the neutral persona and safe tool configuration together. It never combines a persona from one release with tools from another.

Participants with multiple cohort memberships get one deterministic membership by default. The request header can select another current participant membership, but one request never merges cohort configuration.

## Conversation continuity

User and assistant chat messages store the cohort and, when active, the release that produced the turn. Transcript construction always filters both roles to the current cohort and release. Legacy and safe-fallback conversations therefore cannot cross between two cohort memberships, while instructions and answers from an earlier rollout version do not enter the new runtime context. Mia request fingerprints include the cohort and runtime continuity identifier, which prevents a completed request from replaying after either the selected cohort or release changes.

## Activation and rollout

`cohorts.active_cohort_release_id` is the default runtime pointer. `cohort_release_activation_events` is the append-only audit trail for that pointer. The database requires exactly one matching event in the same transaction as every pointer change, validates the claimed prior pointer before insert, and validates the resulting pointer at commit.

`cohort_release_exposures` pins a participant membership epoch to a release. The immutable version 2 plan also stores each participant's membership ID and enrollment timestamp; removal and re-enrollment makes the old plan stale instead of enrolling a new consent epoch implicitly. Any changed planned epoch blocks further waves and completion, including a change in an earlier exposed wave. Rollback remains available as the recovery path. It creates a baseline exposure for each previously exposed epoch that is still current, while removed or replaced epochs need no exposure because they can no longer resolve the target and any replacement already inherits the cohort baseline. Pause, resume, and cancel do not add exposure rows. Append order, rather than wall-clock time, determines the effective exposure.

Release rows and their linked publication evidence are immutable. The request resolver caches only the integrity and runtime-compatibility verdict in a bounded in-process store keyed by immutable release digests and the current runtime contract. Activation and rollout mutations always run uncached integrity checks. A cache failure is fail-closed and returns the neutral safe bundle.

Database checks reject:

- cross-workspace or cross-cohort releases;
- fictitious, stale, nonparticipant, or cross-cohort membership epochs;
- exposure rows for the wrong wave or user;
- incomplete wave or rollback sets;
- activation events that do not match their pointer change, rollout, or completed transition;
- updates or deletes to exposure and activation evidence.

## Deployment sequence

1. Deploy the nullable pointers, evidence tables, runtime resolver, and legacy fallback together.
2. Close any rollout created with operation version 1. The Studio reports the blocker; planned rollouts can be cancelled, while active or paused rollouts can resume, complete, or roll back through the preserved version 1 path.
3. Run `bin/rails cohort_releases:activate_runtime`.
4. Review each cohort result. The task reuses a compatible sealed release or seals one deterministic reconciliation release, verifies parity with the legacy bundle, changes the pointer with compare-and-swap locking, and records activation evidence.
5. Retry errors after correcting the reported cohort. Successful cohorts are idempotent and remain auditable.

The task refuses to activate a cohort with an open pre-cutover rollout. A failure in one cohort is reported without hiding the results for other cohorts. The migration is intentionally irreversible because rollback would discard append-only activation and participant exposure history.
