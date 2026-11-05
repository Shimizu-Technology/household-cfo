import { beforeEach, expect, it, vi } from 'vitest'
import type { CohortExperienceConfiguration, CohortExperiencePreview } from '../api'
import { reviewCoachSettings, toolChanges } from './coachSettingsReview'
const api=vi.hoisted(()=>({fetchWorkspaceBrand:vi.fn(),previewWorkspaceBrand:vi.fn(),fetchCohortExperienceConfiguration:vi.fn(),previewCohortExperienceConfiguration:vi.fn()}))
vi.mock('../api',()=>api)
const brand={draft_revision:2,permissions:{preview:true,publish:true}}
const tools={cohort:{id:42,name:'Practice people'},draft_revision:4,permissions:{review:true,publish:true}}
beforeEach(()=>{vi.resetAllMocks();api.fetchWorkspaceBrand.mockResolvedValue(brand);api.previewWorkspaceBrand.mockResolvedValue({brand_configuration:brand,preview:{digest:'brand'}});api.fetchCohortExperienceConfiguration.mockResolvedValue(tools);api.previewCohortExperienceConfiguration.mockResolvedValue({experience_configuration:tools,preview:{digest:'tools',modules:[]}})})
it('reviews saved settings without a publication from the browser',async()=>{
 const review=await reviewCoachSettings([42],()=>true)
 expect(review.brand.configuration).toEqual(brand)
 expect(review.tools[0].configuration).toEqual(tools)
 expect(api.previewWorkspaceBrand).toHaveBeenCalledWith(2)
 expect(api.previewCohortExperienceConfiguration).toHaveBeenCalledWith(42,4,true)
})
it('stops when context is lost or the program lacks review authority',async()=>{
 await expect(reviewCoachSettings([42],()=>false)).rejects.toThrow('program changed')
 api.fetchWorkspaceBrand.mockResolvedValue({...brand,permissions:{preview:false,publish:false}})
 await expect(reviewCoachSettings([42],()=>true)).rejects.toThrow('program owner or reviewer')
})
it('keeps the upgraded schema and Statements notice in the reviewed request',async()=>{
 const upgraded={...tools,draft_revision:5}
 api.previewCohortExperienceConfiguration.mockResolvedValue({experience_configuration:upgraded,preview:{digest:'new',upgrade_notice:'This update adds Statements',modules:[]}})
 const review=await reviewCoachSettings([42],()=>true)
 expect(review.tools[0].configuration.draft_revision).toBe(5)
 expect(review.tools[0].preview.upgrade_notice).toBe('This update adds Statements')
})

it('names added and removed tools on a second review even when they are under More',()=>{
 const configuration={published_version:{config:{schema_version:4,experience_mode:'household_cfo',optional_modules:{cfo_filter:false,optionality:true}}},draft:{experience_mode:'household_cfo'}} as CohortExperienceConfiguration
 const preview={modules:[{id:'cfo_filter',label:'CFO Filter',enabled:true,core:false},{id:'optionality',label:'Optionality',enabled:false,core:false}]} as CohortExperiencePreview
 expect(toolChanges({configuration,preview})).toEqual(['Adds CFO Filter.','Removes Optionality.'])
})

it('CR20 compares tools with the active group release even after Advanced publishes the draft',()=>{
 const configuration={published_version:{config:{optional_modules:{cfo_filter:true}}},draft:{experience_mode:'household_cfo'}} as CohortExperienceConfiguration
 const preview={modules:[{id:'cfo_filter',label:'CFO Filter',enabled:true,core:false}]} as CohortExperiencePreview
 const active={optional_modules:{cfo_filter:false}} as NonNullable<CohortExperienceConfiguration['published_version']>['config']
 expect(toolChanges({configuration,preview},active)).toEqual(['Adds CFO Filter.'])
})
