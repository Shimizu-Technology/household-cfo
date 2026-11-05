import { beforeEach, expect, it, vi } from 'vitest'
import { reviewCoachGroup } from './coachGoLive'
import type { AdminPersonaAssignableCohort } from '../api'
const api=vi.hoisted(()=>({fetchCohortReleaseStudio:vi.fn(),fetchCohortRolloutStudio:vi.fn(),fetchAdminCohortPersonaAssignment:vi.fn()}))
vi.mock('../api',()=>api)
const group={id:42,name:'Practice people'} as AdminPersonaAssignableCohort
const candidate={bundle_digest:'bundle'}
const rollout={current_roster:{participants:[{user_id:7}],digest:'roster'},active_release:null,open_rollout:null,permissions:{manage:true}}
beforeEach(()=>{vi.resetAllMocks();api.fetchCohortReleaseStudio.mockResolvedValue({candidate,permissions:{seal:true}});api.fetchCohortRolloutStudio.mockResolvedValue(rollout);api.fetchAdminCohortPersonaAssignment.mockResolvedValue({persona:{id:8}})})
it('freezes the reviewed bundle roster assignment and active release for the atomic request',async()=>{
 expect(await reviewCoachGroup(group)).toEqual({group,candidate,participantIds:[7],rosterDigest:'roster',activeReleaseId:null,assignmentPersonaId:8})
})
it.each(['rollout','permission','candidate'])('refuses an existing update or unavailable review: %s',async(reason)=>{
 if(reason==='rollout')api.fetchCohortRolloutStudio.mockResolvedValue({...rollout,open_rollout:{id:1}})
 if(reason==='permission')api.fetchCohortRolloutStudio.mockResolvedValue({...rollout,permissions:{manage:false}})
 if(reason==='candidate')api.fetchCohortReleaseStudio.mockResolvedValue({candidate:null,permissions:{seal:true}})
 await expect(reviewCoachGroup(group)).rejects.toThrow('Finish the existing group update')
})
it('allows an empty first launch but explains the empty live group update requirement',async()=>{
 api.fetchCohortRolloutStudio.mockResolvedValue({...rollout,current_roster:{participants:[],digest:'empty'}})
 expect((await reviewCoachGroup(group)).participantIds).toEqual([])
 api.fetchCohortRolloutStudio.mockResolvedValue({...rollout,current_roster:{participants:[],digest:'empty'},active_release:{id:3}})
 await expect(reviewCoachGroup(group)).rejects.toThrow('Add a participant')
})

it('warns about named participant conflicts before approval but allows unpublished settings to be prepared',async()=>{
 api.fetchCohortReleaseStudio.mockResolvedValue({candidate,permissions:{seal:true},readiness:{blockers:['Maria has different assistant or tools settings. Remove the extra group in Participant access.']}})
 await expect(reviewCoachGroup(group)).rejects.toThrow('Maria')
})
