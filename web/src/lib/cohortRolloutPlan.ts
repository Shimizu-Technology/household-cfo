import type { CohortRolloutPlanInput, CohortRolloutStudio } from '../api'

export type CohortRolloutPlanWave = {
  key: string
  name: string
}

export type CohortRolloutPlanDraft = {
  waves: CohortRolloutPlanWave[]
  participantWaveKeys: Record<number, string>
}

export type CohortRolloutPlanValidation = {
  input: CohortRolloutPlanInput | null
  errors: string[]
}

export function defaultCohortRolloutPlan(studio: CohortRolloutStudio): CohortRolloutPlanDraft {
  const firstWave = { key: 'wave-1', name: 'All participants' }
  return {
    waves: [firstWave],
    participantWaveKeys: Object.fromEntries(
      studio.current_roster.participants.map((participant) => [participant.user_id, firstWave.key]),
    ),
  }
}

export function nextCohortRolloutWaveKey(draft: CohortRolloutPlanDraft): string {
  const used = new Set(draft.waves.map((wave) => wave.key))
  let number = 1
  while (used.has(`wave-${number}`)) number += 1
  return `wave-${number}`
}

export function serializeCohortRolloutPlan(
  studio: CohortRolloutStudio,
  draft: CohortRolloutPlanDraft,
): CohortRolloutPlanValidation {
  const errors: string[] = []
  const target = studio.latest_release
  if (!target) errors.push('Seal a cohort release before planning a rollout.')
  if (draft.waves.length === 0) errors.push('Add at least one rollout wave.')

  const names = draft.waves.map((wave) => wave.name.trim())
  names.forEach((name, index) => {
    if (!name) errors.push(`Name wave ${index + 1}.`)
    if (name.length > 80) errors.push(`Keep wave ${index + 1}'s name to 80 characters or fewer.`)
  })
  if (new Set(names.map((name) => name.toLowerCase())).size !== names.length) {
    errors.push('Give every rollout wave a different name.')
  }

  const waveKeys = new Set(draft.waves.map((wave) => wave.key))
  const participantIds = studio.current_roster.participants.map((participant) => participant.user_id)
  const unknownAssignments = Object.keys(draft.participantWaveKeys)
    .map(Number)
    .filter((userId) => !participantIds.includes(userId))
  if (unknownAssignments.length > 0) errors.push('The participant list changed. Reload the cohort before planning.')

  for (const participant of studio.current_roster.participants) {
    if (!waveKeys.has(draft.participantWaveKeys[participant.user_id])) {
      errors.push(`Choose a wave for ${participant.full_name}.`)
    }
  }

  const waves = draft.waves.map((wave, index) => ({
    name: names[index],
    user_ids: participantIds.filter((userId) => draft.participantWaveKeys[userId] === wave.key),
  }))
  waves.forEach((wave) => {
    if (wave.user_ids.length === 0) errors.push(`${wave.name || 'Each wave'} must include at least one participant.`)
  })

  if (!target || errors.length > 0) return { input: null, errors: [...new Set(errors)] }
  return {
    input: {
      target_release_id: target.id,
      expected_latest_release_id: target.id,
      expected_roster_digest: studio.current_roster.digest,
      waves,
    },
    errors: [],
  }
}

export function cohortRolloutPlanDirty(studio: CohortRolloutStudio, draft: CohortRolloutPlanDraft): boolean {
  const baseline = defaultCohortRolloutPlan(studio)
  return JSON.stringify(draft) !== JSON.stringify(baseline)
}
