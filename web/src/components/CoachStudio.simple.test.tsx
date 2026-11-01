// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import type { CurrentUser } from '../api'
import { CoachStudio } from './CoachStudio'
const api=vi.hoisted(()=>({createAdminPersona:vi.fn(),fetchAdminPersonas:vi.fn(),fetchAdminPersona:vi.fn(),fetchAdminPersonaAssignableCohorts:vi.fn()}))
vi.mock('../api',()=>api)
vi.mock('../contexts/authContextValue',()=>({useAuthContext:()=>({activeCoachWorkspaceId:1,selectCoachWorkspace:vi.fn()})}))
vi.mock('./CoachStudioAdvanced',()=>({CoachStudioAdvanced:({embedded,onDirtyChange}:{embedded:boolean;onDirtyChange:(dirty:boolean)=>void})=><><p>{embedded?'People and invitations':'Full settings and history'}</p><button onClick={()=>onDirtyChange(true)}>Unsaved group edit</button></>}))
vi.mock('./CoachProgramSettings',()=>({CoachProgramSettings:()=>null}));vi.mock('./CohortExperienceStudio',()=>({CohortExperienceStudio:()=>null}));vi.mock('./CoachContentLibrary',()=>({CoachContentLibrary:()=>null}));vi.mock('./PersonaSetupChat',()=>({PersonaSetupChat:()=> <p>Describe with transcripts</p>}));vi.mock('./CoachGoLive',()=>({CoachGoLive:()=> <p>Review saved answers and groups</p>}));
const user={coach_workspaces:[{id:1,name:'Practice coaching'}]} as CurrentUser
beforeEach(()=>{window.sessionStorage.clear();vi.resetAllMocks();api.fetchAdminPersonas.mockResolvedValue([]);api.fetchAdminPersonaAssignableCohorts.mockResolvedValue([])})
afterEach(cleanup)
it('has three default areas and a short setup checklist without release terminology',async()=>{
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);await screen.findByText('Get your program ready');
 const areas=screen.getByRole('navigation',{name:'Coach Studio areas'});
 expect(within(areas).getAllByRole('button').map(item=>item.textContent)).toEqual(['People','Your assistant','Go live']);
 expect(screen.queryByText(/server revision|release candidate|wave|phrase audience/)).toBeNull();
 fireEvent.click(within(areas).getByRole('button',{name:'Your assistant'}));
 expect(screen.getByLabelText('Assistant name')).toHaveProperty('value', 'Mia');
 expect(screen.getByText('More settings',{selector:'summary'}).closest('details')?.open).toBe(false);
 fireEvent.click(screen.getByText('More settings',{selector:'summary'}));
 expect(screen.getByRole('button',{name:'Teaching'})).toBeTruthy();
})
it('creates the assistant then makes describe, preview and advanced history reachable',async()=>{
 api.createAdminPersona.mockResolvedValue({id:8,name:'Lina',draft_revision:1,permissions:{edit:true,publish:true}});
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);await screen.findByText('Get your program ready');
 fireEvent.click(screen.getByRole('button',{name:'Your assistant'}));fireEvent.change(screen.getByLabelText('Assistant name'),{target:{value:'Lina'}});fireEvent.click(screen.getByRole('button',{name:'Describe this assistant'}));
 await screen.findByText('Describe with transcripts');expect(api.createAdminPersona).toHaveBeenCalledWith({name:'Lina',description:''});
 await waitFor(()=>expect(screen.getByRole('button',{name:'Preview answers'})).toHaveProperty('disabled',false));fireEvent.click(screen.getByRole('button',{name:'Preview answers'}));await screen.findByText('Review saved answers and groups');
})

it('keeps only the detailed-view preference when the app remounts after a program switch',async()=>{
 const first=render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);await screen.findByText('Get your program ready');
 fireEvent.click(screen.getByRole('button',{name:'Open advanced settings'}));await screen.findByText('Full settings and history');first.unmount();
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);expect(screen.getByText('Full settings and history')).toBeTruthy();
 fireEvent.click(screen.getByRole('button',{name:'Back to simple setup'}));await screen.findByText('Get your program ready');
 expect(window.sessionStorage.getItem('hcfo.coachStudio.mode:undefined')).toBeNull();
})

it('retains the selected area after an account refresh without retaining private form values',async()=>{
 const first=render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);await screen.findByText('Get your program ready');
 fireEvent.click(screen.getByRole('button',{name:'Your assistant'}));fireEvent.change(screen.getByLabelText('Assistant name'),{target:{value:'Unsaved private name'}});first.unmount();
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);await screen.findByLabelText('Assistant name');
 expect(screen.getByLabelText('Assistant name')).toHaveProperty('value','Mia');
 expect(screen.getByRole('navigation',{name:'Coach Studio areas'}).querySelector('[aria-current=page]')?.textContent).toBe('Your assistant');
})

it('starts describing a default assistant from People without a separate name or create screen',async()=>{
 api.fetchAdminPersonaAssignableCohorts.mockResolvedValue([{id:42,name:'Only group',assignable:true}]);
 api.createAdminPersona.mockResolvedValue({id:8,name:'Mia',draft_revision:1,permissions:{edit:true,publish:true}});
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);
 const start=await screen.findByRole('button',{name:'Describe your assistant'});
 fireEvent.click(start);
 await screen.findByText('Describe with transcripts');
 expect(api.createAdminPersona).toHaveBeenCalledWith({name:'Mia',description:''});
 expect(screen.queryByLabelText('Assistant name')).toBeNull();
 expect(screen.getAllByText('Advanced / history',{selector:'summary'})).toHaveLength(1);
})

it('keeps unsaved group work when the coach declines to leave for quick assistant setup',async()=>{
 const confirm=vi.spyOn(window,'confirm').mockReturnValue(false);
 try{
  render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);
  await screen.findByText('Get your program ready');
  fireEvent.click(screen.getByRole('button',{name:'Unsaved group edit'}));
  fireEvent.click(screen.getByRole('button',{name:'Describe your assistant'}));
  expect(confirm).toHaveBeenCalledWith('Leave without saving these changes?');
  expect(api.createAdminPersona).not.toHaveBeenCalled();
  expect(screen.getByText('People and invitations')).toBeTruthy();
 }finally{confirm.mockRestore()}
})
