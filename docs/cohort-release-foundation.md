# Cohort release foundation

## Purpose

A cohort release is an immutable snapshot of the participant experience that was ready at one point in time. It binds these parts together:

- the exact published coach persona version and evidence digests, or the exact built-in neutral persona snapshot used by legacy runtime;
- the exact published participant-tools version, or the exact safe-default configuration used by legacy runtime;
- the exact module and reviewed-operation registry available in that release;
- tenant, cohort, actor, source, time, and idempotency evidence.

An activated release is the cohort's default participant runtime. Rollout exposure records can pin individual participants to another release while a version 2 rollout is in progress. The resolver always derives persona, approved content, and participant tools from one validated release.

## Evidence and safety rules

- User-created releases require the workspace publish and assign permissions.
- New user releases require a sealed governed persona and a published participant-tools version.
- Legacy reconciliation records the cohort-level configured source. Missing or invalid components are captured as neutral persona or safe-default snapshots without inventing a human actor. Ambiguous multi-cohort participants are reported by count until explicit cohort context ships.
- Release rows are append-only. Restoring a prior governed bundle creates a new release with a source reference. User restores reject legacy fallback, archived or ungoverned personas, unpublished tools, and ambiguous participant cohort configuration.
- Composite foreign keys enforce cohort, workspace, persona, and experience ownership in PostgreSQL.
- Every snapshot, bundle, manifest, and request has a canonical SHA-256 digest.
- Published persona snapshots contain version IDs and evidence digests only. Participant-scoped phrases stay in the sealed persona version and continue through the existing audience filter. The manifest contains no participant names, emails, prompts, messages, household IDs, or financial values.

## Legacy reconciliation

Run the idempotent task after deployment:

```sh
bin/rails cohort_releases:reconcile_legacy
```

The reconciliation task still seals shadow releases without activating them. `CohortReleases::ShadowParity` reports `unreconciled`, `in_sync`, `drifted`, `corrupt`, or `error` using IDs, modes, and counts only. Run `bin/rails cohort_releases:activate_runtime` after closing any pre-cutover open rollout to reuse or seal a matching release, verify legacy parity, activate it, and record an append-only activation event.

## Coach release operations

The coach control plane exposes two typed versioned operations:

- `cohort.release.seal` version 1 records the exact reviewed persona assignment, persona version, participant-tools version, tool registry, candidate bundle, and latest release ID.
- `cohort.release.restore` version 1 records the exact historical source release, source versions and bundle digest, and latest release ID.

Both operations require an explicit `Idempotency-Key`. The first completed request returns `201`; an exact replay returns `200`. Reusing a key for different normalized input returns `409`. A new key cannot seal the bundle already present in the latest record or restore the latest bundle.

`CoachOperationExecution` is an append-only audit ledger. It stores tenant and actor provenance, canonical input, before and predicted state, the actual after state, the linked release, and SHA-256 digests. Its snapshots contain identifiers, counts, versions, and digests only. PostgreSQL composite keys keep the execution, cohort, workspace, and release in one tenant, and a database trigger rejects updates and deletes.

The release Studio API is available at:

- `GET /api/v1/admin/cohorts/:cohort_id/releases`
- `POST /api/v1/admin/cohorts/:cohort_id/releases`
- `POST /api/v1/admin/cohorts/:cohort_id/releases/:id/restore`

Readiness is evidence state and remains visible to read-only workspace members. Mutation permissions and closed-cohort restrictions are reported separately. Release records remain inert until activation or rollout exposure. Studio responses identify the active release, each participant's effective release, open-rollout baseline, exposure completeness, and pre-cutover blockers.

## Runtime activation

Activation is atomic and auditable. The database requires the pointer change and its matching from/to event in the same transaction. Replaying the activation task checks the existing event and active pointer before considering newer equivalent releases, so sealing another release with the same bundle does not invalidate prior activation evidence.

The participant resolver keeps a deployment-safe legacy fallback for cohorts that have not been activated. Once a release is selected, it validates and loads the release as one unit. Corrupt release data falls back to the neutral persona and safe participant tools together.
