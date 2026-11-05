// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import type { CurrentUser } from '../api'
import { useLayoutEffect } from 'react'
import { CoachStudio } from './CoachStudio'
const auth=vi.hoisted(()=>({workspaceId:1,initialAdvancedDirty:false}))
const api=vi.hoisted(()=>({createAdminPersona:vi.fn(),fetchAdminPersonas:vi.fn(),fetchAdminPersona:vi.fn(),fetchAdminPersonaAssignableCohorts:vi.fn()}))
vi.mock('../api',()=>api)
vi.mock('../contexts/authContextValue',()=>({useAuthContext:()=>({activeCoachWorkspaceId:auth.workspaceId,selectCoachWorkspace:vi.fn()})}))
vi.mock('./CoachStudioAdvanced',()=>({CoachStudioAdvanced:function Advanced({embedded,onDirtyChange,onPendingChange,onGroupsChanged}:{embedded:boolean;onDirtyChange:(dirty:boolean)=>void;onPendingChange?:(pending:boolean)=>void;onGroupsChanged?:()=>void}){useLayoutEffect(()=>{if(!embedded&&auth.initialAdvancedDirty)onDirtyChange(true)},[embedded,onDirtyChange]);return <><p>{embedded?'People and invitations':'Full settings and history'}</p><button onClick={()=>onDirtyChange(true)}>Unsaved group edit</button><button onClick={()=>onPendingChange?.(true)}>Start group mutation</button><button onClick={()=>{onGroupsChanged?.();onPendingChange?.(false)}}>Finish group mutation</button></>}}))
vi.mock('./CoachProgramSettings',()=>({CoachProgramSettings:()=>null}));vi.mock('./CohortExperienceStudio',()=>({CohortExperienceStudio:()=>null}));vi.mock('./CoachContentLibrary',()=>({CoachContentLibrary:()=>null}));vi.mock('./PersonaSetupChat',()=>({PersonaSetupChat:()=> <p>Describe with transcripts</p>}));vi.mock('./CoachGoLive',()=>({CoachGoLive:()=> <p>Review saved answers and groups</p>}));
const user={id:902,coach_workspaces:[{id:1,name:'Practice coaching'},{id:2,name:'Second program'}]} as CurrentUser
beforeEach(()=>{window.sessionStorage.clear();auth.workspaceId=1;auth.initialAdvancedDirty=false;window.history.replaceState(null, '', '/#Coach%20Studio');vi.resetAllMocks();api.fetchAdminPersonas.mockResolvedValue([]);api.fetchAdminPersonaAssignableCohorts.mockResolvedValue([])})
afterEach(cleanup)
it('keeps the next editor dirty when the previous editor unmounts',async()=>{
 const dirty=vi.fn();const confirm=vi.spyOn(window,'confirm').mockReturnValue(false);auth.initialAdvancedDirty=true;
 try{
  render(<CoachStudio currentUser={user} onDirtyChange={dirty}/>);await screen.findByText('Get your program ready');
  fireEvent.click(screen.getByText('Advanced / history',{selector:'summary'}));
  fireEvent.click(screen.getByRole('button',{name:'Open advanced settings'}));
  await screen.findByText('Full settings and history');expect(dirty).toHaveBeenLastCalledWith(true);
  fireEvent.click(screen.getByRole('button',{name:'Back to simple setup'}));
  expect(confirm).toHaveBeenCalledWith('Your changes will be lost.');expect(screen.getByText('Full settings and history')).toBeTruthy();
 }finally{confirm.mockRestore()}
})
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
 fireEvent.click(screen.getByRole('button',{name:'Open advanced settings'}));await screen.findByText('Full settings and history');first.unmount();auth.workspaceId=2;
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);expect(screen.getByText('Full settings and history')).toBeTruthy();
 fireEvent.click(screen.getByRole('button',{name:'Back to simple setup'}));await screen.findByText('Get your program ready');
 expect(window.sessionStorage.getItem('hcfo.coachStudio.mode:902')).toBeNull();
 expect(screen.getByLabelText('Program')).toHaveProperty('value','2');
 expect(screen.getByRole('navigation',{name:'Coach Studio areas'}).querySelector('[aria-current=page]')?.textContent).toBe('People');
})

it('retains the selected area after an account refresh without retaining private form values',async()=>{
 const first=render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);await screen.findByText('Get your program ready');
 fireEvent.click(screen.getByRole('button',{name:'Your assistant'}));fireEvent.change(screen.getByLabelText('Assistant name'),{target:{value:'Unsaved private name'}});first.unmount();
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);await screen.findByLabelText('Assistant name');
 expect(screen.getByLabelText('Assistant name')).toHaveProperty('value','Mia');
 expect(screen.getByRole('navigation',{name:'Coach Studio areas'}).querySelector('[aria-current=page]')?.textContent).toBe('Your assistant');
})

it('switches areas immediately while creating the default assistant from People',async()=>{
 api.fetchAdminPersonaAssignableCohorts.mockResolvedValue([{id:42,name:'Only group',assignable:true}]);
 let finishCreate!:(value:unknown)=>void;
 api.createAdminPersona.mockReturnValue(new Promise(resolve=>{finishCreate=resolve}));
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);
 fireEvent.click(await screen.findByRole('button',{name:'Describe your assistant'}));
 expect(screen.getByRole('navigation',{name:'Coach Studio areas'}).querySelector('[aria-current=page]')?.textContent).toBe('Your assistant');
 expect(api.createAdminPersona).toHaveBeenCalledWith({name:'Mia',description:''});
 expect(screen.getByLabelText('Assistant name')).toHaveProperty('disabled',true);
 finishCreate({id:8,name:'Mia',draft_revision:1,permissions:{edit:true,publish:true}});
 await screen.findByText('Describe with transcripts');
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
  expect(confirm).toHaveBeenCalledWith('Your changes will be lost.');
  expect(api.createAdminPersona).not.toHaveBeenCalled();
  expect(screen.getByText('People and invitations')).toBeTruthy();
 }finally{confirm.mockRestore()}
})

it('opens an existing assistant from the People checklist',async()=>{
 api.fetchAdminPersonas.mockResolvedValue([{id:8,status:'draft'}]);
 api.fetchAdminPersona.mockResolvedValue({id:8,name:'Mia',draft_revision:1,permissions:{edit:true,publish:true}});
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);
 fireEvent.click(await screen.findByRole('button',{name:'Describe your assistant'}));
 await screen.findByText('Describe with transcripts');
 expect(screen.getByRole('navigation',{name:'Coach Studio areas'}).querySelector('[aria-current=page]')?.textContent).toBe('Your assistant');
 expect(api.createAdminPersona).not.toHaveBeenCalled();
})

it('review CodeRabbit focuses the assistant destination immediately and announces creation progress',async()=>{
 let finishCreate!:(value:unknown)=>void;
 api.createAdminPersona.mockReturnValue(new Promise(resolve=>{finishCreate=resolve}));
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);
 fireEvent.click(await screen.findByRole('button',{name:'Describe your assistant'}));
 const destination=screen.getByRole('heading',{name:'Your assistant'});
 expect(document.activeElement).toBe(destination);
 expect(screen.getByRole('status').textContent).toContain('Creating your assistant');
 screen.getByText('More settings',{selector:'summary'}).focus();
 const focused=document.activeElement;
 finishCreate({id:8,name:'Mia',draft_revision:1,permissions:{edit:true,publish:true}});
 await screen.findByText('Describe with transcripts');
 expect(document.activeElement).toBe(focused);
})

it('review CodeRabbit blocks checklist navigation during group mutations and refreshes saved groups',async()=>{
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);
 await screen.findByText('Get your program ready');
 fireEvent.click(screen.getByRole('button',{name:'Start group mutation'}));
 expect(screen.getByRole('button',{name:'Describe your assistant'})).toHaveProperty('disabled',true);
 fireEvent.click(screen.getByRole('button',{name:'Describe your assistant'}));
 expect(api.createAdminPersona).not.toHaveBeenCalled();
 expect(screen.getByText('People and invitations')).toBeTruthy();
 api.fetchAdminPersonaAssignableCohorts.mockResolvedValue([{id:42,name:'Saved group',assignable:true}]);
 fireEvent.click(screen.getByRole('button',{name:'Finish group mutation'}));
 await waitFor(()=>expect(api.fetchAdminPersonaAssignableCohorts).toHaveBeenCalledTimes(2));
 await waitFor(()=>expect(screen.getByRole('button',{name:'Describe your assistant'})).toHaveProperty('disabled',false));
})

it('review CodeRabbit announces creation progress while the name is locked',async()=>{
 api.createAdminPersona.mockReturnValue(new Promise(()=>{}));
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);
 fireEvent.click(await screen.findByRole('button',{name:'Describe your assistant'}));
 expect(screen.getByLabelText('Assistant name')).toHaveProperty('disabled',true);
 expect(screen.getByRole('status').textContent).toContain('Creating your assistant');
})

it('records coach areas in browser history and follows Back and Forward',async()=>{
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);await screen.findByText('Get your program ready')
 fireEvent.click(screen.getByRole('button',{name:'Your assistant'}))
 expect(new URL(location.href).searchParams.get('coach_area')).toBe('assistant')
 fireEvent.click(screen.getByRole('button',{name:'Go live'}))
 expect(new URL(location.href).searchParams.get('coach_area')).toBe('live')
 await act(async()=>{window.history.back();await new Promise(resolve=>setTimeout(resolve,30))})
 await waitFor(()=>expect(screen.getByRole('navigation',{name:'Coach Studio areas'}).querySelector('[aria-current=page]')?.textContent).toBe('Your assistant'))
 await act(async()=>{window.history.forward();await new Promise(resolve=>setTimeout(resolve,30))})
 await waitFor(()=>expect(screen.getByRole('navigation',{name:'Coach Studio areas'}).querySelector('[aria-current=page]')?.textContent).toBe('Go live'))
})

async function travel(direction:'back'|'forward') { await act(async()=>{window.history[direction]();await new Promise(resolve=>setTimeout(resolve,30))}) }
it('R14 cancellation restores the current history entry and discard accepts the original target',async()=>{
 const confirm=vi.spyOn(window,'confirm').mockReturnValue(false)
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);await screen.findByText('Get your program ready')
 fireEvent.click(screen.getByRole('button',{name:'Your assistant'}))
 fireEvent.change(screen.getByLabelText('Assistant name'),{target:{value:'Private edit'}})
 await travel('back');await waitFor(()=>expect(new URL(location.href).searchParams.get('coach_area')).toBe('assistant'))
 expect(screen.getByLabelText('Assistant name')).toHaveProperty('value','Private edit')
 confirm.mockReturnValue(true);await travel('back');await screen.findByText('Get your program ready')
 expect(new URL(location.href).searchParams.get('coach_area')).toBe('people')
 await travel('forward');await screen.findByLabelText('Assistant name')
 expect(new URL(location.href).searchParams.get('coach_area')).toBe('assistant')
 confirm.mockRestore()
})
it('R14 checklist creates exactly one history entry',async()=>{
 window.history.replaceState(null,'','/?coach_task=teaching#Coach%20Studio')
 render(<CoachStudio currentUser={user} onDirtyChange={vi.fn()}/>);await screen.findByText('Get your program ready')
 const push=vi.spyOn(window.history,'pushState')
 fireEvent.click(screen.getByRole('button',{name:'Describe your assistant'}))
 expect(push).toHaveBeenCalledTimes(1);push.mockRestore()
})
