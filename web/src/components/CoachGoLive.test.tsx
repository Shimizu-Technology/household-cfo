// @vitest-environment jsdom
import { useState } from 'react'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import type { AdminPersonaDetail } from '../api'
import { CoachGoLive } from './CoachGoLive'
import { useCoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'
const api = vi.hoisted(() => ({ resolveCoachLaunch:vi.fn(),fetchAdminPersona:vi.fn(),fetchAdminPersonaEvaluationRun:vi.fn(),fetchAdminPersonaReleaseReadiness:vi.fn(),previewAdminPersona:vi.fn(),postCoachLaunch:vi.fn(),runAdminPersonaEvaluation:vi.fn() }))
const groupApi = vi.hoisted(() => ({reviewCoachGroup:vi.fn()}))
vi.mock('../api', () => api)
const settingsApi = vi.hoisted(() => ({ reviewCoachSettings:vi.fn() }))
vi.mock('../lib/coachSettingsReview',async (original)=>({...await original<typeof import('../lib/coachSettingsReview')>(),...settingsApi}))
vi.mock('./CoachProgramSettings',()=>({BrandWelcomePreview:()=> <p>Reviewed appearance</p>}))
vi.mock('../lib/coachGoLive', () => groupApi)
const persona = {id:8,name:'Mia',draft_revision:1,preview:{digest:'preview'},published_version:null,has_unpublished_changes:true,permissions:{publish:true},draft:{identity:{assistant_name:'Mia'}}} as unknown as AdminPersonaDetail
const published = {...persona,has_unpublished_changes:false,published_version:{id:9}} as AdminPersonaDetail
const group = {id:42,name:'Practice people',assignable:true,persona_assignment:null,status:'active' as const,blocked_reason:null}
const ready = {ready:true,candidate:{manifest_digest:'candidate',draft_revision:1},evaluation_run:{id:4,run_digest:'run',passed:true},behavioral_preview_evidence:{valid:true,digest:'behavior',candidate_digest:'candidate',output:'Take one small step.'},approval:{valid:true,approval_digest:'approved'},phrase_audience_reviews:[{artifact_id:'phrase',artifact_fingerprint:'fingerprint',review_state:'missing',phrase:{text:'One small step',meaning:'Make progress gently',allowed_contexts:['general'],frequency:'rare',caution:'Never in crisis.'}}]}
const configuration = { draft_revision: 2, published_version: null, preview: {digest:'settings'} }
function Harness({onChange=vi.fn()}:{onChange?:(value:AdminPersonaDetail)=>void}) { const lifecycle=useCoachWorkspaceMutationLifecycle(1);return <CoachGoLive persona={persona} cohorts={[group]} lifecycle={lifecycle} onPersonaChange={onChange} /> }
async function review() { fireEvent.click(screen.getByRole('button',{name:'Preview answers'}));await screen.findByText('Review before going live') }
async function approve() { await review(); fireEvent.click(screen.getByRole('button',{name:'Approve and go live'})) }
beforeEach(() => {
 vi.resetAllMocks();localStorage.clear()
 settingsApi.reviewCoachSettings.mockResolvedValue({brand:{configuration,preview:{brand:{}}},tools:[]})
 api.previewAdminPersona.mockResolvedValue({behavioral_preview_evidence:ready.behavioral_preview_evidence})
 api.runAdminPersonaEvaluation.mockResolvedValue({evaluation_run:{id:4,status:'passed',passed:true,results:[],run_digest:'run',candidate_digest:'candidate'}})
 api.fetchAdminPersonaReleaseReadiness.mockResolvedValue(ready);api.fetchAdminPersona.mockResolvedValue(persona)
 api.postCoachLaunch.mockResolvedValue({persona:published,launch:{groups:[{id:42,name:'Practice people',challenge_closed:false}]}})
 groupApi.reviewCoachGroup.mockResolvedValue({group,participantIds:[7],rosterDigest:'roster',candidate:{bundle_digest:'bundle'},activeReleaseId:null,assignmentPersonaId:null})
})
afterEach(cleanup)
it('explains the first voice requirement and gives a direct way back to edit it',()=>{
 const edit=vi.fn();function FirstPublish(){const lifecycle=useCoachWorkspaceMutationLifecycle(1);return <CoachGoLive persona={persona} cohorts={[group]} lifecycle={lifecycle} onPersonaChange={vi.fn()} onEditVoice={edit}/>}
 render(<FirstPublish/>);expect(screen.getByText(/You can use the standard voice or edit it first/)).toBeTruthy()
 fireEvent.click(screen.getByRole('button',{name:'Edit assistant’s voice'}));expect(edit).toHaveBeenCalledTimes(1)
})
it('keeps failed preview plain and retryable without publishing',async()=>{
 api.previewAdminPersona.mockResolvedValueOnce({preview:{status:'unavailable'},behavioral_preview_evidence:null})
 render(<Harness/>);fireEvent.click(screen.getByRole('button',{name:'Preview answers'}))
 expect((await screen.findByRole('alert')).textContent).toBe("The preview didn't come through. Try again in a minute.")
 expect(api.postCoachLaunch).not.toHaveBeenCalled();expect(api.runAdminPersonaEvaluation).not.toHaveBeenCalled()
 expect(screen.getByRole('button',{name:'Preview answers'})).toHaveProperty('disabled',false)
 await review();expect(api.previewAdminPersona).toHaveBeenCalledTimes(3)
})
it.each([[403,'permission'],[409,'voice changed'],[422,'needs attention'],[408,"didn't come through"],[429,"didn't come through"],[502,"didn't come through"]])('explains preview HTTP %s',async(status,message)=>{
 api.previewAdminPersona.mockRejectedValueOnce(Object.assign(new Error('internal detail'),{status}))
 render(<Harness/>);fireEvent.click(screen.getByRole('button',{name:'Preview answers'}))
 expect((await screen.findByRole('alert')).textContent).toContain(message);expect(api.postCoachLaunch).not.toHaveBeenCalled()
})
it.each(['revision','run','preview'])('rejects readiness for a different %s before approval',async(changed)=>{
 api.fetchAdminPersonaReleaseReadiness.mockResolvedValue({...ready,...(changed==='revision'?{candidate:{...ready.candidate,draft_revision:2}}:changed==='run'?{evaluation_run:{...ready.evaluation_run,id:5}}:{behavioral_preview_evidence:{...ready.behavioral_preview_evidence,digest:'new-preview'}})})
 render(<Harness/>);fireEvent.click(screen.getByRole('button',{name:'Preview answers'}));await screen.findByRole('alert')
 expect(screen.queryByRole('button',{name:'Approve and go live'})).toBeNull();expect(api.postCoachLaunch).not.toHaveBeenCalled()
})
it('sends one approval with the exact reviewed evidence settings and roster',async()=>{
 const onChange=vi.fn();render(<Harness onChange={onChange}/>);await approve()
 await screen.findByText(/^Live for Practice people/)
 expect(api.postCoachLaunch).toHaveBeenCalledTimes(1)
 expect(api.postCoachLaunch).toHaveBeenCalledWith(expect.objectContaining({persona:expect.objectContaining({id:8,draft_revision:1,candidate:ready.candidate,evaluation_run:ready.evaluation_run,behavioral_preview_evidence:ready.behavioral_preview_evidence}),groups:[expect.objectContaining({id:42,roster_digest:'roster',bundle_digest:'bundle',participant_ids:[7]})]}),expect.any(String))
 expect(onChange).toHaveBeenCalledWith(published);expect(localStorage.length).toBe(0)
})
it('shows immediate progress while the atomic operation is pending',async()=>{
 api.postCoachLaunch.mockReturnValue(new Promise(()=>{}));render(<Harness/>);await approve()
 expect(await screen.findByText(/Saving your assistant and updating Practice people/)).toBeTruthy()
 expect(screen.getByRole('button',{name:'Going live…'})).toHaveProperty('disabled',true)
})
it('recovers a lost response after remount with the same key and reviewed request',async()=>{
 api.postCoachLaunch.mockRejectedValueOnce(new Error('lost response'));const first=render(<Harness/>);await approve();await screen.findByRole('alert')
 const call=api.postCoachLaunch.mock.calls[0];first.unmount();render(<Harness/>)
 fireEvent.click(screen.getByRole('button',{name:'Finish going live'}));await screen.findByText(/^Live for Practice people/)
 expect(api.postCoachLaunch.mock.calls[1]).toEqual(call);expect(api.previewAdminPersona).toHaveBeenCalledTimes(2)
 expect(localStorage.length).toBe(0)
})
it('checks and closes a rejected request before offering a fresh review',async()=>{
 api.postCoachLaunch.mockRejectedValueOnce(Object.assign(new Error('stale'),{status:409}))
 api.resolveCoachLaunch.mockResolvedValue({status:'not_committed',persona})
 render(<Harness/>);await approve();await screen.findByRole('alert')
 expect(localStorage.length).toBe(1)
 fireEvent.click(screen.getByRole('button',{name:'Check this update'}))
 await screen.findByText(/^Nothing went live from this request/)
 expect(api.resolveCoachLaunch).toHaveBeenCalledWith(...api.postCoachLaunch.mock.calls[0])
 expect(screen.getByRole('button',{name:'Preview answers'})).toHaveProperty('disabled',false)
 expect(screen.queryByRole('button',{name:'Finish going live'})).toBeNull();expect(localStorage.length).toBe(0)
})
it('does not send a launch if recovery cannot be saved',async()=>{
 vi.spyOn(Storage.prototype,'setItem').mockImplementationOnce(()=>{throw new Error('Storage full')})
 render(<Harness/>);await approve();await screen.findByRole('alert');expect(api.postCoachLaunch).not.toHaveBeenCalled();vi.restoreAllMocks()
})
it('shows success immediately and removes first-publish copy with stale parent props',async()=>{
 render(<Harness/>);await approve();await screen.findByText(/^Live for Practice people/)
 expect(screen.getByRole('heading',{name:'Your program is live'})).toBeTruthy()
 expect(screen.queryByText(/Preview and approve your assistant’s voice before/)).toBeNull()
})
it('keeps success when parent props refresh and does not restart preview',async()=>{
 function Refreshing(){const [current,setCurrent]=useState(persona);const lifecycle=useCoachWorkspaceMutationLifecycle(1);return <CoachGoLive persona={current} cohorts={[group]} lifecycle={lifecycle} onPersonaChange={setCurrent}/>}
 render(<Refreshing/>);await approve();await screen.findByText(/^Live for Practice people/)
 await waitFor(()=>expect(screen.getByRole('button',{name:'Review changes'})).toHaveProperty('disabled',false))
 expect(settingsApi.reviewCoachSettings).toHaveBeenCalledTimes(1)
})
it('CR21 shows actual Savings navigation and the unopened challenge before approval and after success',async()=>{
 settingsApi.reviewCoachSettings.mockResolvedValue({brand:{configuration,preview:{brand:{}}},tools:[{configuration:{...configuration,cohort:group,draft:{schema_version:4,experience_mode:'savings_challenge'}},preview:{challenge_open:false,upgrade_notice:'This update adds Statements',modules:['home','review','ask_mia','budget','profile','wealth','statements'].map(id=>({id,enabled:true,label:id}))}}]})
 api.postCoachLaunch.mockResolvedValue({persona:published,launch:{groups:[{...group,challenge_closed:true}]}})
 render(<Harness/>);await review();expect(screen.getByText('Savings · Mia · Statements · More: My Profile')).toBeTruthy()
 expect(screen.getByText('This update adds Statements')).toBeTruthy()
 expect(screen.getByText(/program team still needs to open/)).toBeTruthy()
 fireEvent.click(screen.getByRole('button',{name:'Approve and go live'}));expect((await screen.findByText(/^Live for Practice people/)).textContent).toContain('program team still needs to open')
})
it('does not claim an already open challenge still needs opening',async()=>{
 settingsApi.reviewCoachSettings.mockResolvedValue({brand:{configuration,preview:{brand:{}}},tools:[{configuration:{...configuration,cohort:group,draft:{schema_version:4,experience_mode:'savings_challenge'}},preview:{challenge_open:true,modules:[]}}]})
 render(<Harness/>);await review();expect(screen.queryByText(/program team still needs to open/)).toBeNull()
})
it('honors custom participant navigation order and independently hidden Statements',async()=>{
 settingsApi.reviewCoachSettings.mockResolvedValue({brand:{configuration,preview:{brand:{}}},tools:[{configuration:{...configuration,cohort:group,draft:{schema_version:4,experience_mode:'savings_challenge'}},preview:{challenge_open:true,module_order:['wealth','ask_mia','home'],modules:[{id:'home',enabled:true},{id:'ask_mia',enabled:true},{id:'wealth',enabled:true},{id:'statements',enabled:false}]}}]})
 render(<Harness/>);await review();expect(screen.getByText('Wealth · Mia · Savings')).toBeTruthy()
 expect(screen.queryByText('Savings · Mia · Statements · More')).toBeNull()
})

it('approves the digest read after preview rather than the empty digest left by a voice edit',async()=>{
 api.fetchAdminPersona.mockResolvedValueOnce({...persona,preview:null}).mockResolvedValueOnce({...persona,preview:{digest:'fresh-preview'}})
 render(<Harness/>);await approve();await screen.findByText(/^Live for/)
 expect(api.postCoachLaunch.mock.calls[0][0].persona.preview_digest).toBe('fresh-preview')
})
it.each([401,403])('retains an uncertain launch after a lost reply and a %s retry',async(status)=>{
 api.postCoachLaunch.mockRejectedValueOnce(new Error('lost response')).mockRejectedValueOnce(Object.assign(new Error('auth'),{status}))
 render(<Harness/>);await approve();await screen.findByRole('alert')
 fireEvent.click(screen.getByRole('button',{name:'Finish going live'}))
 await waitFor(()=>expect(screen.getByRole('alert').textContent).toContain('Sign in'))
 expect(screen.getByRole('alert').textContent).not.toContain('Nothing went live')
 expect(localStorage.length).toBe(1)
 expect(screen.getByRole('button',{name:'Check this update'})).toBeTruthy()
})

it('escapes repeated server failures only after the server closes the uncommitted request',async()=>{
 api.postCoachLaunch.mockRejectedValue(Object.assign(new Error('commit failed'),{status:500}))
 api.resolveCoachLaunch.mockResolvedValue({status:'not_committed',persona})
 render(<Harness/>);await approve();await screen.findByRole('alert')
 fireEvent.click(screen.getByRole('button',{name:'Finish going live'}))
 await waitFor(()=>expect(api.postCoachLaunch).toHaveBeenCalledTimes(2))
 await waitFor(()=>expect(screen.getByRole('button',{name:'Check this update'})).toHaveProperty('disabled',false))
 expect(localStorage.length).toBe(1)
 fireEvent.click(screen.getByRole('button',{name:'Check this update'}))
 await screen.findByText(/^Nothing went live from this request/)
 expect(localStorage.length).toBe(0)
 await review()
 expect(screen.getByRole('button',{name:'Approve and go live'})).toHaveProperty('disabled',false)
})
it('checking a committed request shows live without resending the launch',async()=>{
 api.postCoachLaunch.mockRejectedValueOnce(new Error('reply lost'))
 api.resolveCoachLaunch.mockResolvedValue({status:'live',persona:published,launch:{groups:[{...group,challenge_closed:false}]}})
 render(<Harness/>);await approve();await screen.findByRole('alert')
 fireEvent.click(screen.getByRole('button',{name:'Check this update'}))
 await screen.findByText(/^Live for Practice people/)
 expect(api.postCoachLaunch).toHaveBeenCalledTimes(1);expect(localStorage.length).toBe(0)
})
it.each([401,403,500])('keeps recovery when checking status fails with %s',async(status)=>{
 api.postCoachLaunch.mockRejectedValueOnce(new Error('reply lost'))
 api.resolveCoachLaunch.mockRejectedValue(Object.assign(new Error('unavailable'),{status}))
 render(<Harness/>);await approve();await screen.findByRole('alert')
 fireEvent.click(screen.getByRole('button',{name:'Check this update'}))
 await waitFor(()=>expect(screen.getByRole('alert').textContent).toContain(status===500?'still could not confirm':'Sign in'))
 expect(localStorage.length).toBe(1);expect(screen.queryByText(/^Nothing went live/)).toBeNull()
})

it('shows a definite server rejection plainly while keeping the receipt available to fence before another review',async()=>{
 api.postCoachLaunch.mockRejectedValueOnce(Object.assign(new Error('Maria needs attention in Participant access before this update can go live.'),{status:409,rejected:true}))
 render(<Harness/>);await approve();await screen.findByRole('alert')
 expect(screen.getByRole('alert').textContent).toContain('Maria needs attention')
 expect(screen.getByRole('alert').textContent).not.toContain('could not confirm')
 expect(localStorage.length).toBe(1)
})

it('explains the second-owner review rule before offering approval',async()=>{
 api.fetchAdminPersonaReleaseReadiness.mockResolvedValue({...ready,blockers:['A different workspace owner or reviewer must complete this review']})
 render(<Harness/>);fireEvent.click(screen.getByRole('button',{name:'Preview answers'}))
 expect((await screen.findByRole('alert')).textContent).toContain('different workspace owner or reviewer')
 expect(screen.queryByRole('button',{name:'Approve and go live'})).toBeNull()
})

it.each([401,403])('explains a first-attempt HTTP %s refusal without claiming uncertainty',async(status)=>{
 api.postCoachLaunch.mockRejectedValueOnce(Object.assign(new Error('Ask a program owner to publish.'),{status}))
 render(<Harness/>);await approve();await screen.findByRole('alert')
 expect(screen.getByRole('alert').textContent).toContain('Sign in with access')
 expect(screen.getByRole('alert').textContent).not.toContain('could not confirm')
})

it('warns about rejected audience phrases before offering overall approval',async()=>{
 api.fetchAdminPersonaReleaseReadiness.mockResolvedValue({...ready,phrase_audience_reviews:[{...ready.phrase_audience_reviews[0],review_state:'rejected'}]})
 render(<Harness/>);fireEvent.click(screen.getByRole('button',{name:'Preview answers'}))
 expect((await screen.findByRole('alert')).textContent).toContain('phrase was rejected')
 expect(screen.queryByRole('button',{name:'Approve and go live'})).toBeNull()
 expect(api.postCoachLaunch).not.toHaveBeenCalled()
})

it('reports the actual length rejection without assuming a teaching method',async()=>{
 const notice='The sample answer was outside the response length you chose, even after one rewrite. Adjust the response length in Teaching, then preview again.'
 api.previewAdminPersona.mockResolvedValueOnce({preview:{status:'unavailable',notice},behavioral_preview_evidence:null})
 render(<Harness/>);fireEvent.click(screen.getByRole('button',{name:'Preview answers'}))
 expect((await screen.findByRole('alert')).textContent).toBe(notice)
 expect(api.postCoachLaunch).not.toHaveBeenCalled()
})

it('uses plain audience and community wording while preserving custom approved text',async()=>{
 const audience={audience:"People participating in the human coach's financial education program.",culture:{context:'Use only cultural and community context explicitly approved by the human coach.'}}
 api.fetchAdminPersonaReleaseReadiness.mockResolvedValue({...ready,candidate:{...ready.candidate,audience_snapshot:audience}})
 render(<Harness/>);await review()
 expect(screen.getByText(/Who this is for: People in your coaching program/)).toBeTruthy()
 expect(screen.getByText(/Only the details you have approved/)).toBeTruthy()
 expect(screen.queryByText(/human coach's financial education/)).toBeNull()
})

it('CR21 shows the ordered secondary tools inside More',async()=>{
 const order=['home','ask_mia','budget','statements','optionality','cfo_filter']
 settingsApi.reviewCoachSettings.mockResolvedValue({brand:{configuration,preview:{brand:{}}},tools:[{configuration:{...configuration,cohort:group,draft:{schema_version:4,experience_mode:'household_cfo'}},preview:{module_order:order,modules:order.map(id=>({id,enabled:true,label:id}))}}]})
 render(<Harness/>);await review()
 expect(screen.getByText('Home · Mia · Budget · Statements · More: Optionality · CFO Filter')).toBeTruthy()
})

it('shows when a preview did not use a coach phrase', async () => {
  api.previewAdminPersona.mockResolvedValue({preview:{status:'ready',phrase_notice:'No coach phrase was used in this sample. Phrases only appear when their context fits.'},behavioral_preview_evidence:ready.behavioral_preview_evidence})
  render(<Harness />)
  await review()
  expect(screen.getAllByText('No coach phrase was used in this sample. Phrases only appear when their context fits.')).toHaveLength(2)
  expect(api.previewAdminPersona.mock.calls[0][2]).toContain('credit card')
})
