# Cohort participant tools

Coach Studio lets an administrator or a coach assigned to a cohort choose which optional teaching tools participants can open. The server remains the source of truth for both navigation and endpoint access.

## Module policy

The following financial control surfaces are always enabled:

- Home
- Review
- Ask Mia
- Budget
- My Profile
- Wealth

The first coach-controlled modules are CFO Filter and Optionality. A coach cannot disable a core module through the API or the UI.

Existing cohorts receive a published version with both optional modules enabled when the migration runs. New cohorts begin with the core experience only. A participant without a cohort keeps the full standalone experience. A participant whose cohort configuration is missing, unpublished, or malformed receives the core experience only.

## Draft and publication lifecycle

Each cohort has one editable configuration and immutable published versions:

1. Save an optional-module draft. Every saved change increments its revision and invalidates the previous preview.
2. Preview that exact revision. The response shows the participant navigation for desktop and phone layouts.
3. Publish using the current draft revision, preview digest, and current published-version ID. These compare-and-set fields prevent one coach from overwriting another coach's work.
4. Restore an earlier version when needed. Restore creates a new immutable version and audit event; it does not modify history.

Draft, preview, publish, and restore are available to administrators and coaches assigned to the cohort. Completed and archived cohorts are read-only. Participants cannot access these endpoints.

## Participant enforcement

`GET /api/v1/workspace` includes `workspace.capabilities`, resolved from the same effective cohort membership used for the Mia persona. The web app builds participant navigation only after that response arrives.

When an optional module is disabled:

- its payload is omitted from the workspace response;
- its direct API endpoint returns `403` with `code: "module_disabled"`;
- Mia's context states which product modules are available;
- its navigation link is absent; and
- a saved hash link redirects to Home and focuses a visible live-region explanation.

The browser check is a usability measure. The API check is the authorization boundary.

## API endpoints

All paths below are under `/api/v1/admin/cohorts/:cohort_id`:

- `GET /experience_configuration`
- `PATCH /experience_configuration`
- `POST /experience_configuration/preview`
- `POST /experience_configuration/publish`
- `GET /experience_configuration/versions/:id`
- `POST /experience_configuration/versions/:id/rollback`

The patch body includes `experience_configuration.draft_revision` and `draft_config`. Publish also requires the preview digest and expected published-version ID. Rollback requires the current draft revision and expected published-version ID.

## Operational checks

After deployment:

1. Confirm the migration created one published version for every pre-existing cohort.
2. Open Coach Studio as an assigned coach and verify only manageable cohorts appear.
3. Publish a draft with one optional module disabled in a non-production test cohort.
4. Sign in as its participant and verify navigation, direct hash handling, workspace payload omission, direct endpoint denial, and Mia module awareness.
5. Restore the prior version and confirm the module returns after the participant refreshes.
