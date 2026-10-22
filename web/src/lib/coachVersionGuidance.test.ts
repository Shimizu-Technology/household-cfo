import { expect, it } from 'vitest'
import { coachVersionGuidance } from './coachVersionGuidance'

it('keeps readiness and safety requirements while explaining older API release terms', () => {
  expect(coachVersionGuidance("Activate the cohort's current release before planning a runtime rollout.")).toBe('Launch the group’s current version before planning an update.')
  expect(coachVersionGuidance('No earlier release passed integrity and runtime compatibility checks.')).toBe('No earlier release passed integrity and app compatibility checks.')
  expect(coachVersionGuidance('The latest sealed release changed; reload before planning.')).toBe('The latest saved version changed; reload before planning.')
  expect(coachVersionGuidance('Release #3 does not change participant runtime.')).toBe('version 3 does not change participant settings.')
  expect(coachVersionGuidance('Add at least one participant before planning a rollout.')).toBe('Add at least one participant before planning a rollout.')
})
