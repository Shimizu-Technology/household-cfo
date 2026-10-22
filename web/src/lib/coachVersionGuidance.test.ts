import { expect, it } from 'vitest'
import { coachVersionGuidance } from './coachVersionGuidance'

it('keeps readiness and safety requirements while explaining older API release terms', () => {
  expect(coachVersionGuidance("Activate the cohort's current release before planning a runtime rollout.")).toBe('Launch the group’s current version before planning an update.')
  expect(coachVersionGuidance('No earlier release passed integrity and runtime compatibility checks.')).toBe('No earlier version passed integrity and app compatibility checks.')
  expect(coachVersionGuidance('The latest sealed release changed; reload before planning.')).toBe('The latest saved version changed; reload before planning.')
  expect(coachVersionGuidance('Release #3 does not change participant runtime.')).toBe('version 3 does not change participant settings.')
  expect(coachVersionGuidance('Add at least one participant before planning a rollout.')).toBe('Add at least one participant before planning a group update.')
})

it('explains an already active version without release-engine instructions', () => {
  expect(coachVersionGuidance('The published settings changed. Seal their new release before launching.')).toBe('The published settings changed. Prepare their new version before launching.')
  expect(coachVersionGuidance('Seal a new release before planning a rollout; the latest release is already active.')).toBe('Prepare a new version before updating this group; the latest version is already in use.')
})

it('translates every form of the older seal wording, including -ing and cohort', () => {
  expect(coachVersionGuidance('Publish the workspace brand before sealing a cohort release.')).toBe('Publish the workspace brand before preparing a version for this group.')
  expect(coachVersionGuidance('The latest sealed record changed; reload before sealing')).toBe('The latest saved record changed; reload before preparing')
  for (const text of ['Sealing or restoring a release record does not change the brand.', 'Each advanced wave receives the sealed brand.']) {
    expect(coachVersionGuidance(text)).not.toMatch(/seal|cohort|runtime|rollout/i)
  }
})
