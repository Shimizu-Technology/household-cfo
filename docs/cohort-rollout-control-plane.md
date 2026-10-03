# Cohort rollout control plane

## Purpose

A cohort rollout is an audited plan for introducing one sealed cohort release to a reviewed participant roster in ordered waves. Version 2 connects each rollout decision to participant runtime. Version 1 remains readable and executable only so an open rollout created before the cutover can reach a terminal state.

Starting or advancing a version 2 wave pins that wave's exact participants to the target release. Completing the rollout makes the target the cohort default. Rolling back pins every participant exposed by that rollout to the captured baseline. Pause, resume, and cancel do not change participant runtime.

## Stored evidence

- A version 2 rollout pins one cohort, coach workspace, active baseline release, target release, planner, role, time, immutable wave plan, and immutable participant roster with each participant's membership ID and enrollment timestamp.
- A wave has a stable position, name, and participant set.
- A transition records the actor, role, event, prior and next state, prior and next wave position, time, and any rollback release.
- Starting, advancing, and completing a wave also store the exact SHA-256 readiness digest reviewed for that decision.
- A `CoachOperationExecution` links each API request to exactly one immutable rollout transition and stores canonical input, before state, predicted state, actual state, request fingerprints, and evidence digests.

Names and user IDs are available to the authorized Studio so coaches can operate the cohort. Immutable snapshots and digests exclude email addresses, messages, household IDs, and financial values.

## Lifecycle

```mermaid
stateDiagram-v2
  [*] --> planned: plan
  planned --> active: start first wave
  planned --> cancelled: cancel before start
  active --> active: start next wave
  active --> paused: pause
  paused --> active: resume
  active --> completed: complete after final wave
  active --> rolled_back: record rollback
  paused --> rolled_back: record rollback
```

Only one planned, active, or paused rollout may exist for a cohort. A cohort cannot be completed or archived while a rollout remains open. PostgreSQL serializes rollout creation and cohort closure so concurrent requests cannot bypass that rule. A planned rollout may still be cancelled if legacy data already contains a closed cohort with an open plan.

## Readiness

Readiness is evaluated live for each person in the next wave, in this order:

1. `removed` when the person is no longer a participant in the cohort;
2. `revoked` when account access was revoked;
3. `ready` when the invitation was accepted;
4. `awaiting_acceptance` otherwise.

Every current participant must appear in exactly one wave when the plan is created. The next wave can start only when every participant in that wave is ready and the submitted readiness digest still matches. Completion rechecks the final wave, so its evidence never represents an empty participant set. A changed roster, invitation state, access state, release, rollout state, wave position, or transition history causes the caller to reload rather than recording stale evidence.

The database rechecks the exact roster when the planning transaction commits. A roster change that commits before the plan therefore produces the same reload conflict as an earlier change and leaves no partial rollout evidence. A participant change serialized until after the plan commits remains outside that immutable plan and appears in the Studio as outside the rollout.

## Typed operations

The operation names remain:

- `cohort.rollout.plan`
- `cohort.rollout.advance`
- `cohort.rollout.pause`
- `cohort.rollout.resume`
- `cohort.rollout.cancel`
- `cohort.rollout.rollback`

New plans use operation version 2. The first successful request returns `201`. An exact replay with the same `Idempotency-Key` returns `200` and the original transition. Reusing a key with different normalized input returns `409`. Invalid or incomplete evidence returns `422`; stale state returns `409`; unauthorized actors receive `403`; cross-workspace records resolve as `404`.

An open version 1 rollout has no captured baseline and blocks runtime activation. The API continues to emit version 1 for that rollout's transition requests so a planned rollout can be cancelled and an active or paused rollout can be completed or rolled back. The Studio reports this blocker and the required closing action. After it reaches a terminal state, the runtime activation task can activate the cohort.

The API is available at:

- `GET /api/v1/admin/cohorts/:cohort_id/rollouts`
- `GET /api/v1/admin/cohorts/:cohort_id/rollouts/:id`
- `POST /api/v1/admin/cohorts/:cohort_id/rollouts`
- `POST /api/v1/admin/cohorts/:cohort_id/rollouts/:id/advance`
- `POST /api/v1/admin/cohorts/:cohort_id/rollouts/:id/pause`
- `POST /api/v1/admin/cohorts/:cohort_id/rollouts/:id/resume`
- `POST /api/v1/admin/cohorts/:cohort_id/rollouts/:id/cancel`
- `POST /api/v1/admin/cohorts/:cohort_id/rollouts/:id/rollback`

Workspace owners, reviewers, and platform admins may mutate rollout records. Workspace viewers may inspect the bounded rollout history without mutation controls. The index returns compact rollout summaries plus full details for the open rollout; the detail endpoint returns one rollout's waves, participants, readiness, and transition evidence. History responses report their limit, total count, and whether results were truncated.

Action permissions describe what can succeed from the returned state. Version 2 planning is available only when the cohort has participants, has an active release, and its latest sealed release differs from that active release while passing immutable integrity and runtime compatibility checks; otherwise the payload includes specific plan blockers. A version 2 rollback can restore only the baseline release captured by that rollout. The detailed rollout returns that baseline as `rollback_candidate` when it remains valid and compatible. Historical version 1 rollouts retain their earlier-release lookup so they can reach a terminal state. The response includes specific advance and rollback blockers when an action is unavailable, and legacy candidate lookup uses bounded keyset batches rather than materializing the complete release history.

## Database guarantees

- Composite foreign keys keep the rollout, cohort, workspace, releases, waves, participants, transitions, actors, and operation executions in one tenant.
- A partial unique index allows one open rollout per cohort.
- Plan identity, waves, participant roster, and transitions cannot be updated or deleted.
- Database checks cap plans at 25 waves and 500 participants and enforce valid states, positions, actors, readiness digests, rollback shape, and truthful `participant_runtime_changed` values for each operation version.
- A serialized database trigger enforces the participant cap under concurrent inserts.
- Lifecycle triggers prevent rollout creation for a closed cohort and prevent cohort closure while a rollout is open.
- Operation-result checks prevent release operation keys from being attached to rollout transitions, and prevent rollout operation keys from being attached to releases.
- Deferred plan checks require the pinned target to remain the cohort's latest sealed release when the transaction commits, so a concurrent release cannot leave false “latest release” evidence.
- A locked append guard serializes transition creation. Deferred checks validate each immutable transition, its exact operation evidence, and the latest rollout state in fixed work rather than replaying an unbounded history on every operation.
- Version 2 deferred checks prove exact set equality between each transition wave and its exposure rows. Rollback evidence must restore every distinct participant previously exposed by that rollout.
- Activation evidence and the cohort active-release pointer must describe the same from/to change in the same database transaction. Evidence is append-only, and a pointer cannot move without exactly one matching event.
- Exposure inserts must reference a real current participant membership and its exact enrollment timestamp. Deleting and recreating any planned membership blocks forward progress, preserves old evidence without reusing it for the new membership epoch, and leaves rollback available. Rollback restores still-current exposed epochs and omits removed or replaced epochs that no longer receive the target release.
- `schema.rb` preserves every custom trigger so a fresh schema load retains the production guarantees.

## Runtime behavior

The runtime resolver uses the participant's newest exposure from the current membership epoch, then the cohort's active release, then the legacy mutable configuration during deployment. It validates one release and derives the Mia persona, approved content, and participant tools from that same release. If the selected release is corrupt, the whole bundle falls back to the neutral persona and safe tool configuration.

Chat turns always store their cohort and store the release when one is active. Transcript context stays inside both boundaries, including legacy and safe-fallback use, and request replay fingerprints include the runtime continuity identifier. A participant with more than one cohort gets one deterministic cohort; a valid `X-Cohort-Id` can select another current participant membership without merging their context or releases.
