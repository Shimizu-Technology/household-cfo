// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import type { CurrentUser } from '../api'
import { useLayoutEffect } from 'react'
import { CoachStudio } from './CoachStudio'
import { holdWorkspaceLock } from './coachWorkspaceMutationLifecycle'
const auth=vi.hoisted(()=>({workspaceId:1,initialAdvancedDirty:false}))
const api=vi.hoisted(()=>({createAdminPersona:vi.fn(),fetchAdminPersonas:vi.fn(),fetchAdminPersona:vi.fn(),fetchAdminPersonaAssignableCohorts:vi.fn()}))
vi.mock('../api',()=>api)
vi.mock('../contexts/authContextValue',()=>({useAuthContext:()=>({activeCoachWorkspaceId:auth.workspaceId,selectCoachWorkspace:vi.fn()})}))
vi.mock('./CoachStudioAdvanced',()=>({CoachStudioAdvanced:function Advanced({onDirtyChange}:{onDirtyChange:(dirty:boolean)=>void}){useLayoutEffect(()=>{if(auth.initialAdvancedDirty)onDirtyChange(true)},[onDirtyChange]);return <p>History editor</p>}}))
vi.mock('./CoachContentLibrary',()=>({CoachContentLibrary:()=>null}));vi.mock('./PersonaSetupChat',()=>({PersonaSetupChat:()=> <p>Describe with transcripts</p>}));vi.mock('./CoachGoLive',()=>({CoachGoLive:({onPreviewAnswers,autoPreview}:{onPreviewAnswers:(answers:unknown[],revision:number)=>void;autoPreview?:boolean})=> <><p>Review saved answers and groups</p><output aria-label="Starts a preview">{String(Boolean(autoPreview))}</output><button onClick={()=>onPreviewAnswers([{question:'A question',answer:'New revision sample'}],2)}>Return newer sample</button><button onClick={()=>onPreviewAnswers([{question:'A question',answer:'Matching sample'}],1)}>Return matching sample</button></>}))
const user={id:902,coach_workspaces:[{id:1,name:'Practice coaching'},{id:2,name:'Second program'}]} as CurrentUser
const steps=()=>screen.getByRole('navigation',{name:'Coaching steps'})
const current=()=>steps().querySelector('[aria-current=page]')?.textContent
beforeEach(()=>{window.sessionStorage.clear();auth.workspaceId=1;auth.initialAdvancedDirty=false;window.history.replaceState(null,'','/admin/coaching');vi.resetAllMocks();api.fetchAdminPersonas.mockResolvedValue([]);api.fetchAdminPersona.mockResolvedValue(null);api.fetchAdminPersonaAssignableCohorts.mockResolvedValue([])})
afterEach(cleanup)
it('offers three steps and History, with no People or duplicate Go live tabs',async()=>{
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);await screen.findByLabelText('Assistant name')
 expect(within(steps()).getAllByRole('button').map(item=>item.textContent)).toEqual(['1 · Your coach’s voice','2 · Teaching','3 · Preview and go live'])
 expect(screen.getByRole('heading',{name:'Coaching'})).toBeTruthy()
 expect(screen.getByRole('heading',{name:'History'})).toBeTruthy()
 expect(screen.queryByText(/server revision|release candidate|wave|cohort|Advanced \/ history/i)).toBeNull()
 expect(screen.queryByRole('button',{name:'People'})).toBeNull()
})
it('asks which program to use before showing anything when none is chosen',async()=>{
 auth.workspaceId=null as unknown as number
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>)
 expect(await screen.findByRole('heading',{name:'Choose a program'})).toBeTruthy()
 expect(screen.getByRole('button',{name:'Open Settings'})).toBeTruthy()
})
it('creates the assistant then makes describe and preview reachable',async()=>{
 api.createAdminPersona.mockResolvedValue({id:8,name:'Lina',draft_revision:1,permissions:{edit:true,publish:true}})
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>)
 fireEvent.change(await screen.findByLabelText('Assistant name'),{target:{value:'Lina'}});fireEvent.click(screen.getByRole('button',{name:'Describe this assistant'}))
 await screen.findByText('Describe with transcripts');expect(api.createAdminPersona).toHaveBeenCalledWith({name:'Lina',description:''})
 expect(screen.getByRole('button',{name:'2 · Teaching'})).toBeTruthy()
 await waitFor(()=>expect(screen.getByRole('button',{name:'Preview answers'})).toHaveProperty('disabled',false));fireEvent.click(screen.getByRole('button',{name:'Preview answers'}))
 await screen.findByText('Review saved answers and groups')
 // The button says it previews, so it starts one; opening the step from its tab does not.
 expect(screen.getByLabelText('Starts a preview').textContent).toBe('true')
 fireEvent.click(screen.getByRole('button',{name:'1 · Your coach’s voice'}));fireEvent.click(screen.getByRole('button',{name:'3 · Preview and go live'}))
 expect(screen.getByLabelText('Starts a preview').textContent).toBe('false')
})
it('opens History in place and comes back to Coaching, asking first when changes are unsaved',async()=>{
 const dirty=vi.fn();const confirm=vi.spyOn(window,'confirm').mockReturnValue(false);auth.initialAdvancedDirty=true
 try{
  render(<CoachStudio currentUser={user} onDirtyChange={dirty}/>);await screen.findByLabelText('Assistant name')
  fireEvent.click(screen.getByRole('button',{name:'Open history'}))
  await screen.findByText('History editor');expect(dirty).toHaveBeenLastCalledWith(true)
  fireEvent.click(screen.getByRole('button',{name:'Back to Coaching'}))
  expect(confirm).toHaveBeenCalledWith('Your changes will be lost.');expect(screen.getByText('History editor')).toBeTruthy()
  confirm.mockReturnValue(true);fireEvent.click(screen.getByRole('button',{name:'Back to Coaching'}))
  await screen.findByLabelText('Assistant name');expect(window.sessionStorage.getItem('hcfo.coachStudio.mode:902')).toBeNull()
 }finally{confirm.mockRestore()}
})
it('keeps Group tools open while one of its saves is still going',async()=>{
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);await screen.findByLabelText('Assistant name')
 fireEvent.click(screen.getByRole('button',{name:'Open group tools'}))
 const back=await screen.findByRole('button',{name:'Back to Coaching'});expect(back).toHaveProperty('disabled',false)
 let release=()=>{};act(()=>{release=holdWorkspaceLock()})
 await waitFor(()=>expect(screen.getByRole('button',{name:'Back to Coaching'})).toHaveProperty('disabled',true))
 act(()=>release())
 await waitFor(()=>expect(screen.getByRole('button',{name:'Back to Coaching'})).toHaveProperty('disabled',false))
})
it('keeps only the history preference when the app remounts after a program switch',async()=>{
 const first=render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);await screen.findByLabelText('Assistant name')
 fireEvent.click(screen.getByRole('button',{name:'Open history'}));await screen.findByText('History editor');first.unmount();auth.workspaceId=2
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);expect(screen.getByText('History editor')).toBeTruthy()
 fireEvent.click(screen.getByRole('button',{name:'Back to Coaching'}));await screen.findByLabelText('Assistant name')
 expect(current()).toBe('1 · Your coach’s voice')
})
it('retains the selected step after an account refresh without retaining private form values',async()=>{
 api.fetchAdminPersonas.mockResolvedValue([])
 const first=render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);await screen.findByLabelText('Assistant name')
 fireEvent.change(screen.getByLabelText('Assistant name'),{target:{value:'Unsaved private name'}});first.unmount()
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);await screen.findByLabelText('Assistant name')
 expect(screen.getByLabelText('Assistant name')).toHaveProperty('value','Mia')
})
it('records steps in browser history and follows Back and Forward',async()=>{
 api.fetchAdminPersonas.mockResolvedValue([{id:8,status:'draft'}]);api.fetchAdminPersona.mockResolvedValue({id:8,name:'Mia',draft_revision:1,permissions:{edit:true,publish:true}})
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);await screen.findByText('Describe with transcripts')
 fireEvent.click(within(steps()).getByRole('button',{name:/Preview and go live/}))
 expect(new URL(location.href).searchParams.get('coach_area')).toBe('live')
 await act(async()=>{window.history.back();await new Promise(resolve=>setTimeout(resolve,30))})
 await waitFor(()=>expect(current()).toBe('1 · Your coach’s voice'))
 await act(async()=>{window.history.forward();await new Promise(resolve=>setTimeout(resolve,30))})
 await waitFor(()=>expect(current()).toBe('3 · Preview and go live'))
})

it('never presents a fetched newer-revision sample beside the older saved voice rules', async () => {
 api.fetchAdminPersonas.mockResolvedValue([{id:8,status:'draft'}])
 api.fetchAdminPersona.mockResolvedValue({id:8,name:'Mia',draft_revision:1,permissions:{edit:true,publish:true},draft:{identity:{assistant_name:'Mia'},voice:{tone_traits:['Gentle'],energy:'Calm',accountability_style:'Kind',language_style:['Plain']},coaching:{do:[],do_not:[]}}})
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()} />)
 await screen.findByText('Describe with transcripts')
 fireEvent.click(within(steps()).getByRole('button',{name:/Preview and go live/}))
 fireEvent.click(screen.getByRole('button',{name:'Return newer sample'}))
 const rail = document.querySelector('.coach-authoring-rail')!
 expect(rail.textContent).not.toContain('New revision sample')
 expect(rail.textContent).toContain('A sample appears after a preview.')
 fireEvent.click(screen.getByRole('button',{name:'Return matching sample'}))
 expect(rail.textContent).toContain('Matching sample')
})
