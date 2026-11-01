import { beforeEach, describe, expect, it, vi } from 'vitest'
import { publishCoachGroup, reviewCoachGroup } from './coachGoLive'
import type { AdminPersonaAssignableCohort, CohortReleaseCandidate } from '../api'
const mocks = vi.hoisted(() => ({ advanceCohortRollout: vi.fn(), fetchAdminCohortPersonaAssignment: vi.fn(), fetchCohortInitialLaunch: vi.fn(), fetchCohortReleaseStudio: vi.fn(), fetchCohortRolloutStudio: vi.fn(), launchCohortRelease: vi.fn(), planCohortRollout: vi.fn(), sealCohortRelease: vi.fn(), updateAdminCohortPersonaAssignment: vi.fn() }))
vi.mock('../api', () => mocks)
const group = { id: 42, name: 'Practice people', persona_assignment: null } as AdminPersonaAssignableCohort
const candidate = { ready: true, seal_needed: true, persona_version_id: 9, brand_snapshot_digest: 'brand', experience_version_id: 4, registry_digest: 'registry', registry_version: 5, expected_latest_release_id: null, bundle_digest: 'bundle', assignment_id: 3, brand_version_id: 5 } as CohortReleaseCandidate
const roster = { active_release: null, open_rollout: null, current_roster: { participants: [{user_id: 7}], digest: 'roster' }, permissions: { manage: true, plan: true }, latest_release: { id: 11 } }
beforeEach(() => {
  vi.resetAllMocks()
  mocks.fetchCohortReleaseStudio.mockResolvedValue({candidate, permissions:{seal:true}})
  mocks.fetchCohortRolloutStudio.mockResolvedValue(roster)
  mocks.fetchAdminCohortPersonaAssignment.mockResolvedValue(null)
  mocks.fetchCohortInitialLaunch.mockResolvedValue({ active_release_id: null, release: { id: 11 }, preview_digest: 'launch', can_launch: true })
})
describe('one reviewed coach group publication', () => {
  it('retains exact settings, participant roster, sealed release and launch preconditions', async () => {
    const review = await reviewCoachGroup(group)
    await publishCoachGroup(review, 8, 9, 'request', () => true)
    expect(mocks.updateAdminCohortPersonaAssignment).toHaveBeenCalledWith(42, 8, null)
    expect(mocks.sealCohortRelease).toHaveBeenCalledWith(42, expect.objectContaining({ expected_bundle_digest: 'bundle', expected_experience_version_id: 4, expected_persona_version_id: 9 }), 'request:seal:42')
    expect(mocks.launchCohortRelease).toHaveBeenCalledWith(42, {release_id: 11, preview_digest: 'launch'}, 'request:launch:42')
    expect(mocks.planCohortRollout).not.toHaveBeenCalled()
  })
  it.each(['brand', 'tools', 'roster', 'assignment'])('refuses a concurrent %s change before a write', async (changed) => {
    const review = await reviewCoachGroup(group)
    if (changed === 'brand') mocks.fetchCohortReleaseStudio.mockResolvedValue({candidate:{...candidate,brand_snapshot_digest:'different'}})
    if (changed === 'tools') mocks.fetchCohortReleaseStudio.mockResolvedValue({candidate:{...candidate,experience_version_id:999}})
    if (changed === 'roster') mocks.fetchCohortRolloutStudio.mockResolvedValue({...roster,current_roster:{...roster.current_roster,digest:'different'}})
    if (changed === 'assignment') mocks.fetchAdminCohortPersonaAssignment.mockResolvedValue({persona:{id:99}})
    await expect(publishCoachGroup(review,8,9,'request',()=>true)).rejects.toThrow('changed')
    expect(mocks.updateAdminCohortPersonaAssignment).not.toHaveBeenCalled()
    expect(mocks.sealCohortRelease).not.toHaveBeenCalled()
  })
  it('stops after program context is lost without starting subsequent writes', async () => {
    const review = await reviewCoachGroup(group)
    const current = vi.fn().mockReturnValueOnce(true).mockReturnValue(false)
    await expect(publishCoachGroup(review,8,9,'request',current)).rejects.toThrow('program changed')
    expect(mocks.updateAdminCohortPersonaAssignment).not.toHaveBeenCalled()
  })
  it('keeps an existing controlled group update out of the simple path', async () => {
    mocks.fetchCohortRolloutStudio.mockResolvedValue({...roster,open_rollout:{id:6}})
    await expect(reviewCoachGroup(group)).rejects.toThrow('existing group update')
  })
})
