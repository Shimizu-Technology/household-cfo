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
  mocks.sealCohortRelease.mockResolvedValue({release:{id:11}})
  mocks.fetchCohortReleaseStudio.mockResolvedValue({candidate, permissions:{seal:true}})
  mocks.fetchCohortRolloutStudio.mockResolvedValue(roster)
  mocks.fetchAdminCohortPersonaAssignment.mockResolvedValue(null)
  mocks.fetchCohortInitialLaunch.mockResolvedValue({ active_release_id: null, release: { id: 11 }, preview_digest: 'launch', roster_digest: 'roster', can_launch: true })
})
describe('one reviewed coach group publication', () => {
  it('retains exact settings, participant roster, sealed release and launch preconditions', async () => {
    const review = await reviewCoachGroup(group)
    await publishCoachGroup(review, 8, 9, 'request', () => true)
    expect(mocks.updateAdminCohortPersonaAssignment).toHaveBeenCalledWith(42, 8, null)
    expect(mocks.sealCohortRelease).toHaveBeenCalledWith(42, expect.objectContaining({ expected_bundle_digest: 'bundle', expected_experience_version_id: 4, expected_persona_version_id: 9 }), 'request:seal:42')
    expect(mocks.launchCohortRelease).toHaveBeenCalledWith(42, {release_id: 11, preview_digest: 'launch', expected_roster_digest: 'roster'}, 'request:launch:42')
    expect(mocks.planCohortRollout).not.toHaveBeenCalled()
  })
  it.each(['brand', 'tools', 'roster', 'assignment', 'registry'])('refuses a concurrent %s change before a write', async (changed) => {
    const review = await reviewCoachGroup(group)
    if (changed === 'registry') mocks.fetchCohortReleaseStudio.mockResolvedValue({candidate:{...candidate,registry_digest:'different'}})
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
  it('uses the reviewed published tools and appearance, then advances the existing controlled rollout gates', async () => {
    const active = { ...roster, active_release: { id: 10 } }
    mocks.fetchCohortRolloutStudio.mockResolvedValue(active)
    const review = await reviewCoachGroup(group)
    mocks.fetchCohortReleaseStudio.mockResolvedValue({candidate:{...candidate,brand_version_id:20,experience_version_id:21,registry_digest:'new-schema-catalog'},permissions:{seal:true}})
    mocks.fetchCohortInitialLaunch.mockResolvedValue({active_release_id:10})
    const rollout = { id:30,status:'planned',current_wave_position:null,latest_transition_id:1,next_wave_readiness_digest:'ready',permissions:{advance:true} }
    mocks.planCohortRollout.mockResolvedValue({rollout})
    mocks.advanceCohortRollout.mockResolvedValueOnce({rollout:{...rollout,status:'active',current_wave_position:0,latest_transition_id:2}}).mockResolvedValueOnce({rollout:{...rollout,status:'completed'}})
    await publishCoachGroup(review,8,9,'request',()=>true,{brandVersionId:20,toolVersionIds:{42:21}})
    expect(mocks.planCohortRollout).toHaveBeenCalledWith(42,expect.objectContaining({target_release_id:11,expected_roster_digest:'roster',waves:[{name:'Everyone reviewed',user_ids:[7]}]}),'request:plan:42')
    expect(mocks.advanceCohortRollout).toHaveBeenCalledTimes(2)
    expect(mocks.launchCohortRelease).not.toHaveBeenCalled()
  })
})

it.each(['brand', 'tools', 'registry'])('rechecks concurrent %s changes after assignment and before sealing', async (changed) => {
 const review = await reviewCoachGroup(group)
 const changedCandidate = {...candidate, ...(changed === 'brand' ? {brand_version_id:999,brand_snapshot_digest:'other'} : changed === 'tools' ? {experience_version_id:999} : {registry_digest:'other'})}
 mocks.fetchCohortReleaseStudio.mockResolvedValueOnce({candidate}).mockResolvedValueOnce({candidate:changedCandidate})
 await expect(publishCoachGroup(review,8,9,'request',()=>true,{brandVersionId:5,toolVersionIds:{42:4}})).rejects.toThrow('not ready')
 expect(mocks.sealCohortRelease).not.toHaveBeenCalled()
 expect(mocks.launchCohortRelease).not.toHaveBeenCalled()
})
it.each(['release','roster'])('rejects a new initial-launch %s after sealing', async (changed) => {
 const review = await reviewCoachGroup(group)
 mocks.fetchCohortInitialLaunch.mockResolvedValue({active_release_id:null,release:{id:changed === 'release'?12:11},preview_digest:'fresh',roster_digest:changed === 'roster'?'other':'roster',can_launch:true})
 await expect(publishCoachGroup(review,8,9,'request',()=>true)).rejects.toThrow('could not go live')
 expect(mocks.launchCohortRelease).not.toHaveBeenCalled()
})
it('does not roll out a newer release sealed by another session', async () => {
 mocks.fetchCohortRolloutStudio.mockResolvedValue({...roster,active_release:{id:10}})
 const review = await reviewCoachGroup(group)
 mocks.fetchCohortInitialLaunch.mockResolvedValue({active_release_id:10})
 mocks.fetchCohortRolloutStudio.mockResolvedValueOnce({...roster,active_release:{id:10}}).mockResolvedValueOnce({...roster,active_release:{id:10},latest_release:{id:12}})
 await expect(publishCoachGroup(review,8,9,'request',()=>true)).rejects.toThrow('fresh group review')
 expect(mocks.planCohortRollout).not.toHaveBeenCalled()
})
it('a fresh review recovers an assignment saved by a failed publication despite stale group props', async () => {
 const review = await reviewCoachGroup(group)
 mocks.sealCohortRelease.mockRejectedValueOnce(new Error('connection lost'))
 await expect(publishCoachGroup(review,8,9,'request',()=>true)).rejects.toThrow('connection lost')
 mocks.fetchAdminCohortPersonaAssignment.mockResolvedValue({persona:{id:8}})
 const retry = await reviewCoachGroup(group)
 expect(retry.assignmentPersonaId).toBe(8)
 await publishCoachGroup(retry,8,9,'fresh-request',()=>true)
 expect(mocks.updateAdminCohortPersonaAssignment).toHaveBeenCalledTimes(1)
 expect(mocks.launchCohortRelease).toHaveBeenCalledTimes(1)
})
