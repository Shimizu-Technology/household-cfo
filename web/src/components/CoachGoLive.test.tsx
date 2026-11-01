// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import type { AdminPersonaDetail } from '../api'
import { CoachGoLive } from './CoachGoLive'
import { useCoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'
const api = vi.hoisted(() => ({ fetchAdminPersona:vi.fn(),fetchAdminPersonaEvaluationRun:vi.fn(),fetchAdminPersonaReleaseReadiness:vi.fn(),previewAdminPersona:vi.fn(),publishAdminPersona:vi.fn(),reviewAdminPersonaAudience:vi.fn(),reviewAdminPersonaEvaluation:vi.fn(),runAdminPersonaEvaluation:vi.fn() }))
const groupApi = vi.hoisted(() => ({publishCoachGroup:vi.fn(),reviewCoachGroup:vi.fn()}))
vi.mock('../api', () => api)
vi.mock('../lib/coachGoLive', () => groupApi)
const persona = {id:8,name:'Mia',draft_revision:1,preview:{digest:'preview'},published_version:null,has_unpublished_changes:true,permissions:{publish:true},draft:{identity:{assistant_name:'Lina'}}} as unknown as AdminPersonaDetail
const group = {id:42,name:'Practice people',assignable:true,persona_assignment:null,status:'active' as const,blocked_reason:null}
const ready = {ready:true,candidate:{manifest_digest:'candidate'},evaluation_run:{id:4,run_digest:'run',passed:true},behavioral_preview_evidence:{valid:true,digest:'behavior',output:'Take one small step.'},approval:{valid:true,approval_digest:'approved'},phrase_audience_reviews:[{artifact_id:'phrase',artifact_fingerprint:'fingerprint',review_state:'missing',phrase:{text:'One small step',meaning:'Make progress gently',allowed_contexts:['general'],frequency:'rare',caution:'Never in crisis.'}}]}
function Harness({onChange=vi.fn()}:{onChange?:(value:AdminPersonaDetail)=>void}) { const lifecycle=useCoachWorkspaceMutationLifecycle(1);return <CoachGoLive persona={persona} cohorts={[group]} lifecycle={lifecycle} onPersonaChange={onChange} /> }
beforeEach(() => {vi.resetAllMocks();api.previewAdminPersona.mockResolvedValue({behavioral_preview_evidence:ready.behavioral_preview_evidence});api.runAdminPersonaEvaluation.mockResolvedValue({evaluation_run:{id:4,status:'passed',passed:true,results:[]}});api.fetchAdminPersonaReleaseReadiness.mockResolvedValue(ready);api.fetchAdminPersona.mockResolvedValue(persona);api.publishAdminPersona.mockResolvedValue({persona:{...persona,published_version:{id:9}}});groupApi.reviewCoachGroup.mockResolvedValue({group,participantIds:[7]})})
afterEach(cleanup)
it('requires the actual answers and each phrase to be reviewed before recording approvals and publishing groups',async()=>{
 const onChange=vi.fn();render(<Harness onChange={onChange}/>);
 fireEvent.click(screen.getByRole('button',{name:'Preview answers and check safety'}));
 await screen.findByText('Review before going live');
 expect(api.previewAdminPersona).toHaveBeenCalledTimes(2);
 expect(screen.getByRole('button',{name:'Go live for these groups'})).toHaveProperty('disabled',true);
 fireEvent.click(screen.getByRole('checkbox',{name:/I reviewed the answers/}));
 expect(screen.getByRole('button',{name:'Go live for these groups'})).toHaveProperty('disabled',true);
 fireEvent.click(screen.getByRole('checkbox',{name:/One small step/}));
 fireEvent.click(screen.getByRole('button',{name:'Go live for these groups'}));
 await waitFor(()=>expect(groupApi.publishCoachGroup).toHaveBeenCalledTimes(1));
 expect(api.reviewAdminPersonaAudience).toHaveBeenCalledWith(8,expect.objectContaining({artifact_id:'phrase',decision:'approved',candidate_digest:'candidate'}));
 expect(api.publishAdminPersona).toHaveBeenCalledWith(8,expect.objectContaining({release_candidate_digest:'candidate',behavioral_preview_digest:'behavior',evaluation_approval_digest:'approved'}));
 await waitFor(()=>expect(onChange).toHaveBeenCalled());
})
it('does not publish a voice whose saved revision changed after review',async()=>{
 api.fetchAdminPersona.mockResolvedValue({...persona,draft_revision:2});render(<Harness/>);
 fireEvent.click(screen.getByRole('button',{name:'Preview answers and check safety'}));
 await screen.findByText('Review before going live');
 fireEvent.click(screen.getByRole('checkbox',{name:/I reviewed the answers/}));fireEvent.click(screen.getByRole('checkbox',{name:/One small step/}));fireEvent.click(screen.getByRole('button',{name:'Go live for these groups'}));
 await screen.findByRole('alert');expect(api.publishAdminPersona).not.toHaveBeenCalled();expect(groupApi.publishCoachGroup).not.toHaveBeenCalled();
})
