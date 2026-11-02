import { beforeEach, expect, it, vi } from 'vitest'
import { publishCoachSettings, reviewCoachSettings } from './coachSettingsReview'
const api = vi.hoisted(() => ({ fetchWorkspaceBrand:vi.fn(),previewWorkspaceBrand:vi.fn(),publishWorkspaceBrand:vi.fn(),fetchCohortExperienceConfiguration:vi.fn(),previewCohortExperienceConfiguration:vi.fn(),publishCohortExperienceConfiguration:vi.fn() }))
vi.mock('../api',()=>api)
const brand = { draft_revision:2,has_unpublished_changes:true,preview:{digest:'brand'},published_version:{id:3},permissions:{preview:true,publish:true} }
const tools = { cohort:{id:42,name:'Practice people'},draft_revision:4,has_unpublished_changes:true,preview:{digest:'tools'},published_version:null,permissions:{review:true,publish:true} }
beforeEach(()=>{
 vi.resetAllMocks()
 api.fetchWorkspaceBrand.mockResolvedValue(brand)
 api.previewWorkspaceBrand.mockResolvedValue({brand_configuration:brand,preview:{digest:'brand'}})
 api.fetchCohortExperienceConfiguration.mockResolvedValue(tools)
 api.previewCohortExperienceConfiguration.mockResolvedValue({experience_configuration:tools,preview:{digest:'tools',modules:[]}})
 api.publishWorkspaceBrand.mockResolvedValue({published_version:{id:8}})
 api.publishCohortExperienceConfiguration.mockResolvedValue({published_version:{id:9}})
})
it('reviews and publishes saved appearance and first-launch tools under existing exact preview gates',async()=>{
 const review = await reviewCoachSettings([42],()=>true)
 expect(api.publishWorkspaceBrand).not.toHaveBeenCalled()
 expect(await publishCoachSettings(review,'request',()=>true)).toEqual({brandVersionId:8,toolVersionIds:{42:9}})
 expect(api.publishWorkspaceBrand).toHaveBeenCalledWith({draft_revision:2,preview_digest:'brand',expected_published_version_id:3},'request:appearance')
 expect(api.publishCohortExperienceConfiguration).toHaveBeenCalledWith(42,{draft_revision:4,preview_digest:'tools',expected_published_version_id:null})
})
it('does not make redundant versions when the saved settings already match publication',async()=>{
 api.previewWorkspaceBrand.mockResolvedValue({brand_configuration:{...brand,has_unpublished_changes:false},preview:{digest:'brand'}})
 api.previewCohortExperienceConfiguration.mockResolvedValue({experience_configuration:{...tools,has_unpublished_changes:false,published_version:{id:6}},preview:{digest:'tools'}})
 api.fetchCohortExperienceConfiguration.mockResolvedValue({...tools,published_version:{id:6}})
 const review=await reviewCoachSettings([42],()=>true)
 expect(await publishCoachSettings(review,'request',()=>true)).toEqual({brandVersionId:3,toolVersionIds:{42:6}})
 expect(api.publishWorkspaceBrand).not.toHaveBeenCalled();expect(api.publishCohortExperienceConfiguration).not.toHaveBeenCalled()
})
it.each(['appearance','tools'])('refuses a changed %s before publishing any settings',async(changed)=>{
 const review=await reviewCoachSettings([42],()=>true)
 if(changed==='appearance')api.fetchWorkspaceBrand.mockResolvedValue({...brand,draft_revision:9})
 else api.fetchCohortExperienceConfiguration.mockResolvedValue({...tools,published_version:{id:99}})
 await expect(publishCoachSettings(review,'request',()=>true)).rejects.toThrow('changed')
 expect(api.publishWorkspaceBrand).not.toHaveBeenCalled();expect(api.publishCohortExperienceConfiguration).not.toHaveBeenCalled()
})
it('stops when program context is lost and refuses insufficient review authority',async()=>{
 api.fetchWorkspaceBrand.mockResolvedValue({...brand,permissions:{preview:false,publish:false}})
 await expect(reviewCoachSettings([42],()=>true)).rejects.toThrow('program owner or reviewer')
 expect(api.previewWorkspaceBrand).not.toHaveBeenCalled()
 await expect(reviewCoachSettings([42],()=>false)).rejects.toThrow('program changed')
})
