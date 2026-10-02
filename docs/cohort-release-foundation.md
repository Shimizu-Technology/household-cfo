# Cohort release foundation

## Purpose

A cohort release is an immutable snapshot of the participant experience that was ready at one point in time. It binds these parts together:

- the exact published coach persona version and evidence digests, or the exact built-in neutral persona snapshot used by legacy runtime;
- the exact published participant-tools version, or the exact safe-default configuration used by legacy runtime;
- the exact module and reviewed-operation registry available in that release;
- tenant, cohort, actor, source, time, and idempotency evidence.

This foundation does not change participant runtime. Persona assignments and participant-tools publication remain the live sources until the atomic activation and runtime-cutover work lands. That avoids two competing definitions of the active participant experience.

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

The task seals shadow releases and reports counts. It does not activate them. `CohortReleases::ShadowParity` reports `unreconciled`, `in_sync`, `drifted`, `corrupt`, or `error` using IDs, modes, and counts only.

## Planned cutover

The later activation change must load one release once per request and derive both persona and tools from that row. The same change will add release-scoped conversation continuity, explicit handling for participants in multiple cohorts, activation audit events, and a compare-and-swap cohort pointer. Mutable rollout waves and participant exposure records will reference immutable releases rather than changing release evidence.
