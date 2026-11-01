// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import type { AdminPersonaDetail } from '../api'
import { CoachGoLive } from './CoachGoLive'
import { useCoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'
const api = vi.hoisted(() => ({ fetchAdminPersona:vi.fn(),fetchAdminPersonaEvaluationRun:vi.fn(),fetchAdminPersonaReleaseReadiness:vi.fn(),previewAdminPersona:vi.fn(),publishAdminPersona:vi.fn(),reviewAdminPersonaAudience:vi.fn(),reviewAdminPersonaEvaluation:vi.fn(),runAdminPersonaEvaluation:vi.fn() }))
const groupApi = vi.hoisted(() => ({publishCoachGroup:vi.fn(),reviewCoachGroup:vi.fn()}))
vi.mock('../api', () => api)
const settingsApi = vi.hoisted(() => ({ reviewCoachSettings:vi.fn(), publishCoachSettings:vi.fn() }))
vi.mock('../lib/coachSettingsReview',()=>settingsApi)
vi.mock('./CoachProgramSettings',()=>({BrandWelcomePreview:()=> <p>Reviewed appearance</p>}))
vi.mock('../lib/coachGoLive', () => groupApi)
const persona = {id:8,name:'Mia',draft_revision:1,preview:{digest:'preview'},published_version:null,has_unpublished_changes:true,permissions:{publish:true},draft:{identity:{assistant_name:'Lina'}}} as unknown as AdminPersonaDetail
const group = {id:42,name:'Practice people',assignable:true,persona_assignment:null,status:'active' as const,blocked_reason:null}
const ready = {ready:true,candidate:{manifest_digest:'candidate',draft_revision:1},evaluation_run:{id:4,run_digest:'run',passed:true},behavioral_preview_evidence:{valid:true,digest:'behavior',candidate_digest:'candidate',output:'Take one small step.'},approval:{valid:true,approval_digest:'approved'},phrase_audience_reviews:[{artifact_id:'phrase',artifact_fingerprint:'fingerprint',review_state:'missing',phrase:{text:'One small step',meaning:'Make progress gently',allowed_contexts:['general'],frequency:'rare',caution:'Never in crisis.'}}]}
function Harness({onChange=vi.fn()}:{onChange?:(value:AdminPersonaDetail)=>void}) { const lifecycle=useCoachWorkspaceMutationLifecycle(1);return <CoachGoLive persona={persona} cohorts={[group]} lifecycle={lifecycle} onPersonaChange={onChange} /> }
beforeEach(() => {vi.resetAllMocks();settingsApi.reviewCoachSettings.mockResolvedValue({brand:{preview:{brand:{}}},tools:[]});settingsApi.publishCoachSettings.mockResolvedValue({brandVersionId:5,toolVersionIds:{42:4}});api.previewAdminPersona.mockResolvedValue({behavioral_preview_evidence:ready.behavioral_preview_evidence});api.runAdminPersonaEvaluation.mockResolvedValue({evaluation_run:{id:4,status:'passed',passed:true,results:[],run_digest:'run',candidate_digest:'candidate'}});api.fetchAdminPersonaReleaseReadiness.mockResolvedValue(ready);api.fetchAdminPersona.mockResolvedValue(persona);api.publishAdminPersona.mockResolvedValue({persona:{...persona,published_version:{id:9}}});groupApi.reviewCoachGroup.mockResolvedValue({group,participantIds:[7]})})
afterEach(cleanup)
it('combines explicit approval of displayed answers and phrases with going live',async()=>{
 const onChange=vi.fn();render(<Harness onChange={onChange}/>);
 fireEvent.click(screen.getByRole('button',{name:'Preview answers'}));
 await screen.findByText('Review before going live');
 expect(api.previewAdminPersona).toHaveBeenCalledTimes(2);
 expect(screen.queryByRole('button',{name:'Preview answers'})).toBeNull();
 expect(screen.getByRole('button',{name:'Approve and go live'})).toHaveProperty('disabled',false);
 expect(screen.queryByRole('checkbox',{name:/One small step/})).toBeNull();
 expect(screen.getByText(/By choosing Approve and go live/)).toBeTruthy();
 fireEvent.click(screen.getByRole('button',{name:'Approve and go live'}));
 await waitFor(()=>expect(groupApi.publishCoachGroup).toHaveBeenCalledTimes(1));
 expect(api.reviewAdminPersonaAudience).toHaveBeenCalledWith(8,expect.objectContaining({artifact_id:'phrase',decision:'approved',candidate_digest:'candidate'}));
 expect(api.publishAdminPersona).toHaveBeenCalledWith(8,expect.objectContaining({release_candidate_digest:'candidate',behavioral_preview_digest:'behavior',evaluation_approval_digest:'approved'}));
 await waitFor(()=>expect(onChange).toHaveBeenCalled());
})
it('does not publish a voice whose saved revision changed after review',async()=>{
 api.fetchAdminPersona.mockResolvedValueOnce(persona).mockResolvedValueOnce(persona).mockResolvedValue({...persona,draft_revision:2});render(<Harness/>);
 fireEvent.click(screen.getByRole('button',{name:'Preview answers'}));
 await screen.findByText('Review before going live');fireEvent.click(screen.getByRole('button',{name:'Approve and go live'}));
 await screen.findByRole('alert');expect(api.publishAdminPersona).not.toHaveBeenCalled();expect(groupApi.publishCoachGroup).not.toHaveBeenCalled();
})

it('scopes completed groups and published assistant to one review even while mounted with stale parent props',async()=>{
 const published={...persona,has_unpublished_changes:false,published_version:{id:9}};
 const onChange=vi.fn();render(<Harness onChange={onChange}/>);
 fireEvent.click(screen.getByRole('button',{name:'Preview answers'}));
 await screen.findByText('Review before going live');fireEvent.click(screen.getByRole('button',{name:'Approve and go live'}));
 await waitFor(()=>expect(onChange).toHaveBeenCalledTimes(1));
 api.fetchAdminPersona.mockResolvedValue(published);
 fireEvent.click(screen.getByRole('button',{name:'Preview answers'}));
 await screen.findByText('Review before going live');fireEvent.click(screen.getByRole('button',{name:'Approve and go live'}));
 await waitFor(()=>expect(onChange).toHaveBeenCalledTimes(2));
 expect(groupApi.publishCoachGroup).toHaveBeenCalledTimes(2);
 expect(api.publishAdminPersona).toHaveBeenCalledTimes(1);
 expect(api.previewAdminPersona).toHaveBeenCalledTimes(2);
})
it('requires a fresh review after partial publication instead of retrying stale assignments or settings',async()=>{
 groupApi.publishCoachGroup.mockRejectedValueOnce(new Error('seal unavailable'));
 render(<Harness/>);fireEvent.click(screen.getByRole('button',{name:'Preview answers'}));
 await screen.findByText('Review before going live');fireEvent.click(screen.getByRole('button',{name:'Approve and go live'}));
 await screen.findByRole('alert');
 expect(screen.queryByRole('button',{name:'Approve and go live'})).toBeNull();
 expect(screen.getByRole('button',{name:'Preview answers'})).toHaveProperty('disabled',false);
})

it.each(['revision','run','preview'])('rejects readiness for a different %s before displaying approval controls',async(changed)=>{
 const mismatch={...ready,...(changed==='revision'?{candidate:{...ready.candidate,draft_revision:2}}:changed==='run'?{evaluation_run:{...ready.evaluation_run,id:5}}:{behavioral_preview_evidence:{...ready.behavioral_preview_evidence,digest:'new-preview'}})};
 api.fetchAdminPersonaReleaseReadiness.mockResolvedValue(mismatch);
 render(<Harness/>);fireEvent.click(screen.getByRole('button',{name:'Preview answers'}));
 await screen.findByRole('alert');
 expect(screen.queryByRole('checkbox',{name:/I reviewed the answers/})).toBeNull();
 expect(api.reviewAdminPersonaEvaluation).not.toHaveBeenCalled();expect(api.reviewAdminPersonaAudience).not.toHaveBeenCalled();
})
it('rechecks evaluation identity before recording any approval when another review finishes after display',async()=>{
 render(<Harness/>);fireEvent.click(screen.getByRole('button',{name:'Preview answers'}));
 await screen.findByText('Review before going live');
 api.fetchAdminPersonaReleaseReadiness.mockResolvedValue({...ready,evaluation_run:{...ready.evaluation_run,id:5,run_digest:'new-run'}});fireEvent.click(screen.getByRole('button',{name:'Approve and go live'}));
 await screen.findByRole('alert');expect(api.reviewAdminPersonaEvaluation).not.toHaveBeenCalled();expect(api.reviewAdminPersonaAudience).not.toHaveBeenCalled();expect(settingsApi.publishCoachSettings).not.toHaveBeenCalled();
})

it('prepares published group changes automatically and keeps the only group selected for one confirmation',async()=>{
 const published={...persona,has_unpublished_changes:false,published_version:{id:9}} as AdminPersonaDetail;
 api.fetchAdminPersona.mockResolvedValue(published);
 function PublishedHarness(){const lifecycle=useCoachWorkspaceMutationLifecycle(1);return <CoachGoLive persona={published} cohorts={[group]} lifecycle={lifecycle} onPersonaChange={vi.fn()}/>}
 render(<PublishedHarness/>);
 await screen.findByText('Review before going live');
 expect(screen.getByRole('checkbox',{name:'Practice people'})).toHaveProperty('checked',true);
 expect(api.previewAdminPersona).not.toHaveBeenCalled();
 expect(screen.queryByRole('button',{name:'Review changes'})).toBeNull();
 expect(api.runAdminPersonaEvaluation).not.toHaveBeenCalled();
 expect(screen.getByText('Your assistant’s voice stays the same. Review the appearance, tools and groups below.')).toBeTruthy();
 expect(screen.getByText('By choosing Approve and go live, you approve the appearance, tools and group changes shown above.')).toBeTruthy();
 fireEvent.click(screen.getByRole('button',{name:'Approve and go live'}));
 await waitFor(()=>expect(groupApi.publishCoachGroup).toHaveBeenCalledTimes(1));
 expect(api.publishAdminPersona).not.toHaveBeenCalled();
 expect(screen.queryByRole('button',{name:'Approve and go live'})).toBeNull();
})
