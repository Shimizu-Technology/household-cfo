import { describe, expect, it } from 'vitest'
import type { CohortRolloutStudio } from '../api'
import {
  cohortRolloutPlanDirty,
  defaultCohortRolloutPlan,
  nextCohortRolloutWaveKey,
  serializeCohortRolloutPlan,
} from './cohortRolloutPlan'

const releaseBrandEvidence = {
  manifest_schema: 'cohort_release_manifest_v2',
  brand_mode: 'published_version',
  brand_version_id: 9,
  brand_snapshot_digest: 'brand-v9',
}

function studioFixture(): CohortRolloutStudio {
  const activeRelease = { ...releaseBrandEvidence, id: 21, release_number: 2, bundle_digest: 'baseline', integrity_valid: true, runtime_compatible: true, released_at: '2026-10-02T01:00:00Z' }
  return {
    cohort: { id: 12, name: 'Tuesday cohort', status: 'active', participant_count: 2 },
    runtime_truth: { changes_participant_runtime: false, participant_runtime_changed: false, message: 'Evidence only.' },
    permissions: { view: true, manage: true, plan: true, actor_role: 'owner', blockers: [], plan_blockers: [] },
    current_roster: {
      digest: 'roster-digest', readiness_digest: 'readiness-digest', total_count: 2,
      counts: { ready: 2, awaiting_acceptance: 0, revoked: 0, removed: 0 },
      participants: [
        { user_id: 3, full_name: 'Ana Cruz', readiness: 'ready', exposed: null, effective_release: activeRelease },
        { user_id: 7, full_name: 'Ben Santos', readiness: 'ready', exposed: null, effective_release: activeRelease },
      ],
    },
    latest_release: { ...releaseBrandEvidence, id: 22, release_number: 3, bundle_digest: 'bundle', integrity_valid: true, runtime_compatible: true, released_at: '2026-10-03T01:00:00Z' },
    active_release: activeRelease,
    release_history: { limit: 25, total_count: 1, truncated: false }, releases: [],
    history: { limit: 25, total_count: 0, truncated: false }, open_rollout: null, rollouts: [],
  }
}

describe('cohort rollout plan builder', () => {
  it('starts with one understandable wave containing every participant', () => {
    const studio = studioFixture()
    const draft = defaultCohortRolloutPlan(studio)
    expect(draft).toEqual({
      waves: [{ key: 'wave-1', name: 'All participants' }],
      participantWaveKeys: { 3: 'wave-1', 7: 'wave-1' },
    })
    expect(serializeCohortRolloutPlan(studio, draft)).toEqual({
      errors: [],
      input: {
        target_release_id: 22,
        expected_latest_release_id: 22,
        expected_roster_digest: 'roster-digest',
        waves: [{ name: 'All participants', user_ids: [3, 7] }],
      },
    })
    expect(cohortRolloutPlanDirty(studio, draft)).toBe(false)
  })

  it('serializes named waves in visible order and rejects empty or duplicate names', () => {
    const studio = studioFixture()
    const draft = defaultCohortRolloutPlan(studio)
    draft.waves = [{ key: 'wave-1', name: 'Pilot' }, { key: 'wave-2', name: 'Pilot' }]
    draft.participantWaveKeys[7] = 'wave-2'
    expect(serializeCohortRolloutPlan(studio, draft)).toMatchObject({ input: null, errors: ['Give every rollout wave a different name.'] })
    draft.waves[1].name = 'Everyone else'
    expect(serializeCohortRolloutPlan(studio, draft).input?.waves).toEqual([
      { name: 'Pilot', user_ids: [3] },
      { name: 'Everyone else', user_ids: [7] },
    ])
    expect(cohortRolloutPlanDirty(studio, draft)).toBe(true)
    expect(nextCohortRolloutWaveKey(draft)).toBe('wave-3')
  })

  it('rejects an empty wave, missing release, and stale participant assignment', () => {
    const studio = studioFixture()
    const draft = defaultCohortRolloutPlan(studio)
    draft.waves.push({ key: 'wave-2', name: 'Later' })
    draft.participantWaveKeys[99] = 'wave-2'
    studio.latest_release = null
    const result = serializeCohortRolloutPlan(studio, draft)
    expect(result.input).toBeNull()
    expect(result.errors).toEqual(expect.arrayContaining([
      'Seal a cohort release before planning a rollout.',
      'The participant list changed. Reload the cohort before planning.',
      'Later must include at least one participant.',
    ]))
  })

  it('rejects wave names longer than the server-supported 80 characters', () => {
    const studio = studioFixture()
    const draft = defaultCohortRolloutPlan(studio)
    draft.waves[0].name = 'A'.repeat(81)
    expect(serializeCohortRolloutPlan(studio, draft)).toEqual({
      input: null,
      errors: ["Keep wave 1's name to 80 characters or fewer."],
    })
  })
})
