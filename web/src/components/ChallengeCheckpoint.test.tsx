// @vitest-environment jsdom
import {cleanup,fireEvent,render,screen,waitFor} from '@testing-library/react'
import {afterEach,beforeEach,expect,it,vi} from 'vitest'
import {fetchDailyPage,fetchFinancialBaseline,fetchSavingsPage} from '../api'
import {dailyContext,dailySnapshot} from '../test/dailyFixtures'
import {baselineScope,baselineCurrent} from '../test/baselineFixtures'
import {ChallengeCheckpoints,CheckpointFacts} from './ChallengeCheckpoint'
import type{DailyMutate}from'../lib/useDailyMutation'
vi.mock('../api',async(original)=>({...await original<typeof import('../api')>(),fetchDailyPage:vi.fn(),fetchFinancialBaseline:vi.fn(),fetchSavingsPage:vi.fn()}))
const mutate=vi.fn<DailyMutate>();const onDenied=vi.fn();const scope={...baselineScope,enrollment_id:100}
const view=()=> <ChallengeCheckpoints context={dailyContext} scope={scope} refresh={0} mutate={mutate} busy={false} onDenied={onDenied} onBaseline={vi.fn()}/>
afterEach(cleanup)
beforeEach(()=>{vi.clearAllMocks();vi.mocked(fetchDailyPage).mockResolvedValue({actor_scope:baselineScope,records:[],next_cursor:null});vi.mocked(fetchFinancialBaseline).mockResolvedValue(baselineCurrent());mutate.mockResolvedValue({id:900})})
it('keeps known approved money separate from pending final confirmation and zero supported subset',()=>{render(<CheckpointFacts snapshot={dailySnapshot}/>);expect(screen.getByText('$550.00')).toBeTruthy();expect(screen.getByText('$0.00')).toBeTruthy();expect(screen.getByText(/Pending — known approved savings remain counted/)).toBeTruthy();expect(screen.getByText('Target reached')).toBeTruthy();expect(screen.getByText(/89 unreported days/)).toBeTruthy()})
it('stages the server-calculated milestone without entering totals and without default final confirmation',async()=>{render(view());await waitFor(()=>expect((screen.getByRole('button',{name:'Review Day 90 · 2026-09-28'}) as HTMLButtonElement).disabled).toBe(false));fireEvent.click(screen.getByRole('button',{name:'Review Day 90 · 2026-09-28'}));fireEvent.click(screen.getByRole('checkbox',{name:/Prepare this exact milestone/}));fireEvent.click(screen.getByRole('button',{name:'Save Day 90 checkpoint preview'}));await waitFor(()=>expect(mutate).toHaveBeenCalledWith('checkpoint_stage',{milestone_day:90,expected_version_id:null,expected_head_lock_version:0,reason:'',final_confirmation_accepted:false}));expect(JSON.stringify(mutate.mock.calls[0])).not.toContain('reported_cents')})
it('requires separate saved snapshot approval with captured draft/head locks',async()=>{vi.mocked(fetchDailyPage).mockImplementation(async collection=>({actor_scope:baselineScope,records:collection==='checkpoint_drafts'?[{id:900,lock_version:2,base_version_id:800,base_head_lock_version:3,status:'pending',approved_version_id:null,reason:'Checked correction',snapshot:dailySnapshot,savings_checkpoint_id:700}]:[],next_cursor:null}));render(view());const approval=await screen.findByRole('button',{name:'Approve Day 90 checkpoint'});expect((approval as HTMLButtonElement).disabled).toBe(true);fireEvent.click(screen.getByRole('checkbox',{name:/I reviewed this exact as-of date/}));fireEvent.click(approval);expect(mutate).toHaveBeenCalledWith('checkpoint_approve',{draft_id:900,accepted:true,expected_draft_lock_version:2,expected_version_id:800,expected_head_lock_version:3})})

it('opens an existing milestone with current version locks and preserves the original target by default',async()=>{const head={id:800,current_version_id:801,lock_version:3,milestone_day:90,current_version:{id:801,version_number:1,previous_version_id:null,approved_at:'2026-10-05T00:00:00Z',reason:null,savings_checkpoint_id:800,snapshot:dailySnapshot}};vi.mocked(fetchDailyPage).mockImplementation(async collection=>({actor_scope:baselineScope,records:collection==='checkpoints'?[head]:[],next_cursor:null}));render(view());await waitFor(()=>expect((screen.getByRole('button',{name:'Review Day 90 · 2026-09-28'}) as HTMLButtonElement).disabled).toBe(false));fireEvent.click(screen.getByRole('button',{name:'Review Day 90 · 2026-09-28'}));fireEvent.change(screen.getByLabelText('Checkpoint explanation (required for correction)'),{target:{value:'Included newly approved daily reports.'}});fireEvent.click(screen.getByRole('checkbox',{name:/Prepare this exact milestone/}));fireEvent.click(screen.getByRole('button',{name:'Save Day 90 checkpoint preview'}));await waitFor(()=>expect(mutate).toHaveBeenCalledWith('checkpoint_stage',expect.objectContaining({expected_version_id:801,expected_head_lock_version:3})));expect(mutate.mock.calls[0][1]).not.toHaveProperty('plan_version_id')})

it('rejects milestone identities from another enrollment before preparing a checkpoint',async()=>{
 vi.mocked(fetchDailyPage).mockResolvedValue({actor_scope:baselineScope,enrollment_id:101,cohort_id:55,records:[],next_cursor:null})
 render(<ChallengeCheckpoints context={{...dailyContext,cohort_id:55}} scope={{...scope,cohort_id:55}} refresh={0} mutate={mutate} busy={false} onDenied={onDenied} onBaseline={vi.fn()}/>)
 await waitFor(()=>expect(onDenied).toHaveBeenCalled());expect((screen.getByRole('button',{name:'Review Day 90 · 2026-09-28'}) as HTMLButtonElement).disabled).toBe(true)
})
it.each([{}, {actor_scope:baselineScope,enrollment_id:101,cohort_id:55}, {actor_scope:baselineScope,enrollment_id:100,cohort_id:56}])('fails closed on target correction pages without this selected-program identity %j',async identity=>{
 const head={id:800,current_version_id:801,lock_version:3,milestone_day:90,current_version:{id:801,version_number:1,previous_version_id:null,approved_at:'2026-10-05T00:00:00Z',reason:null,savings_checkpoint_id:800,snapshot:dailySnapshot}}
 vi.mocked(fetchDailyPage).mockImplementation(async collection=>({actor_scope:baselineScope,enrollment_id:100,cohort_id:55,records:collection==='checkpoints'?[head]:[],next_cursor:null}))
 vi.mocked(fetchSavingsPage).mockResolvedValue({...identity,records:[{id:99,version_number:9,target_cents:98765,previous_version_id:null,approval_sequence:9,reason:'Reviewed fictional target.',approved_at:'2026-09-28T12:00:00Z'}],next_cursor:null})
 render(<ChallengeCheckpoints context={{...dailyContext,cohort_id:55}} scope={{...scope,cohort_id:55}} refresh={0} mutate={mutate} busy={false} onDenied={onDenied} onBaseline={vi.fn()}/>)
 fireEvent.click(await screen.findByRole('button',{name:'Correct Day 90 checkpoint'}));fireEvent.click(screen.getByRole('checkbox',{name:/Review a different accepted target/}))
 await waitFor(()=>expect(onDenied).toHaveBeenCalled());expect(screen.queryByRole('option',{name:/Version 9/})).toBeNull()
})
it('allows a target correction only from the exact selected enrollment page',async()=>{
 const head={id:800,current_version_id:801,lock_version:3,milestone_day:90,current_version:{id:801,version_number:1,previous_version_id:null,approved_at:'2026-10-05T00:00:00Z',reason:null,savings_checkpoint_id:800,snapshot:dailySnapshot}}
 vi.mocked(fetchDailyPage).mockImplementation(async collection=>({actor_scope:baselineScope,enrollment_id:100,cohort_id:55,records:collection==='checkpoints'?[head]:[],next_cursor:null}))
 vi.mocked(fetchSavingsPage).mockResolvedValue({actor_scope:baselineScope,enrollment_id:100,cohort_id:55,records:[{id:99,version_number:9,target_cents:98765,previous_version_id:null,approval_sequence:9,reason:'Reviewed fictional target.',approved_at:'2026-09-28T12:00:00Z'}],next_cursor:null})
 render(<ChallengeCheckpoints context={{...dailyContext,cohort_id:55}} scope={{...scope,cohort_id:55}} refresh={0} mutate={mutate} busy={false} onDenied={onDenied} onBaseline={vi.fn()}/>)
 fireEvent.click(await screen.findByRole('button',{name:'Correct Day 90 checkpoint'}));fireEvent.click(screen.getByRole('checkbox',{name:/Review a different accepted target/}))
 await screen.findByRole('option',{name:/Version 9/});fireEvent.change(screen.getByLabelText('Accepted target version'),{target:{value:'99'}})
 fireEvent.change(screen.getByLabelText('Checkpoint explanation (required for correction)'),{target:{value:'Reviewed this target change.'}})
 fireEvent.click(screen.getByRole('checkbox',{name:/Prepare this exact milestone/}));fireEvent.click(screen.getByRole('button',{name:'Save Day 90 checkpoint preview'}))
 await waitFor(()=>expect(mutate).toHaveBeenCalledWith('checkpoint_stage',expect.objectContaining({plan_version_id:99,plan_correction_accepted:true})));expect(onDenied).not.toHaveBeenCalled()
})
