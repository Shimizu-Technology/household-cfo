// @vitest-environment jsdom
import { useState } from 'react'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import type { AdminPersonaDetail, CurrentUser } from '../api'
import { CoachTeaching, CoachTeachingWorkspace } from './CoachTeaching'
import { useCoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'
const api=vi.hoisted(()=>({updateAdminPersona:vi.fn()}))
vi.mock('../api',()=>api)
vi.mock('./CoachContentLibrary',()=>({CoachContentLibrary:({onDirtyChange,onPersonaChange,selectedPersona}:{onDirtyChange:(dirty:boolean)=>void;onPersonaChange:(persona:AdminPersonaDetail)=>void;selectedPersona:AdminPersonaDetail})=><><label>Library draft<input onChange={event=>onDirtyChange(Boolean(event.target.value))}/></label><button onClick={()=>onPersonaChange({...selectedPersona,draft_revision:selectedPersona.draft_revision!+1})}>Attach library collection</button></>}))
const persona={id:8,draft_revision:1,draft:{coaching:{method:'Ask one question.'}},permissions:{edit:true}} as unknown as AdminPersonaDetail
const dirty=vi.fn(),preview=vi.fn()
function Harness(){const [current,setCurrent]=useState(persona);const lifecycle=useCoachWorkspaceMutationLifecycle(1);return <CoachTeachingWorkspace persona={current} currentUser={{id:902} as CurrentUser} lifecycle={lifecycle} onDirtyChange={dirty} onPersonaChange={setCurrent} onPreview={preview}/>}
beforeEach(()=>{vi.resetAllMocks();api.updateAdminPersona.mockResolvedValue({...persona,draft_revision:2,draft:{coaching:{method:'Ask a kind question.'}}})})
afterEach(()=>{cleanup();vi.restoreAllMocks()})
it('keeps combined dirty state when the teaching method is reverted while the library is unsaved',async()=>{
 render(<Harness/>);fireEvent.change(screen.getByLabelText('Library draft'),{target:{value:'Keep this private draft'}})
 fireEvent.change(screen.getByLabelText('Teaching method'),{target:{value:'A different method'}})
 fireEvent.change(screen.getByLabelText('Teaching method'),{target:{value:'Ask one question.'}})
 await waitFor(()=>expect(dirty).toHaveBeenLastCalledWith(true));expect(screen.getByLabelText('Library draft')).toHaveProperty('value','Keep this private draft')
 fireEvent.change(screen.getByLabelText('Library draft'),{target:{value:''}})
 await waitFor(()=>expect(dirty).toHaveBeenLastCalledWith(false))
})
it('keeps unsaved library work after saving teaching when navigation is declined, then previews after it is saved',async()=>{
 const confirm=vi.spyOn(window,'confirm').mockReturnValue(false)
 render(<Harness/>);fireEvent.change(screen.getByLabelText('Library draft'),{target:{value:'Private library wording'}});fireEvent.change(screen.getByLabelText('Teaching method'),{target:{value:'Ask a kind question.'}})
 fireEvent.click(screen.getByRole('button',{name:'Save and preview answers'}))
 await screen.findByRole('status');expect(api.updateAdminPersona).toHaveBeenCalledWith(8,expect.objectContaining({draft_revision:1}));expect(confirm).toHaveBeenCalledTimes(1);expect(preview).not.toHaveBeenCalled()
 expect(screen.getByLabelText('Teaching method')).toHaveProperty('value','Ask a kind question.');expect(screen.getByLabelText('Library draft')).toHaveProperty('value','Private library wording');expect(dirty).toHaveBeenLastCalledWith(true)
 fireEvent.change(screen.getByLabelText('Library draft'),{target:{value:''}});await waitFor(()=>expect(dirty).toHaveBeenLastCalledWith(false))
 fireEvent.click(screen.getByRole('button',{name:'Preview saved teaching'}));expect(preview).toHaveBeenCalledTimes(1);expect(confirm).toHaveBeenCalledTimes(1)
})
it('keeps an unsaved method through a library revision update and saves it against the new revision',async()=>{
 const method='Keep this unsaved teaching method.'
 api.updateAdminPersona.mockResolvedValue({...persona,draft_revision:3,draft:{coaching:{method}}})
 render(<Harness/>);fireEvent.change(screen.getByLabelText('Teaching method'),{target:{value:method}})
 fireEvent.click(screen.getByRole('button',{name:'Attach library collection'}))
 expect(screen.getByLabelText('Teaching method')).toHaveProperty('value',method)
 expect(dirty).toHaveBeenLastCalledWith(true)
 expect(api.updateAdminPersona).not.toHaveBeenCalled()
 fireEvent.click(screen.getByRole('button',{name:'Save and preview answers'}))
 await waitFor(()=>expect(preview).toHaveBeenCalledTimes(1))
 expect(api.updateAdminPersona).toHaveBeenCalledWith(8,expect.objectContaining({draft_revision:2,draft_config:{coaching:{method}}}))
 await waitFor(()=>expect(dirty).toHaveBeenLastCalledWith(false))
})
it('allows explicit discard before moving from saved teaching to preview',async()=>{
 vi.spyOn(window,'confirm').mockReturnValue(true);render(<Harness/>);fireEvent.change(screen.getByLabelText('Library draft'),{target:{value:'Discard with consent'}});fireEvent.change(screen.getByLabelText('Teaching method'),{target:{value:'Ask a kind question.'}});fireEvent.click(screen.getByRole('button',{name:'Save and preview answers'}));await waitFor(()=>expect(preview).toHaveBeenCalledTimes(1))
})

const originalPersona={id:8,draft_revision:3,permissions:{edit:true},draft:{coaching:{method:"Choose a manageable step.",do_not:["Never shame."]},guardrails:{locked:true}}} as unknown as AdminPersonaDetail
const simpleLifecycle={pending:false,begin:vi.fn(()=>({id:1,workspaceId:2})),isCurrent:vi.fn(()=>true),finish:vi.fn()}
beforeEach(()=>{simpleLifecycle.begin.mockReturnValue({id:1,workspaceId:2});simpleLifecycle.isCurrent.mockReturnValue(true)})
it('saves only the teaching edit at the reviewed revision and hands the saved assistant to preview',async()=>{
 const saved={...originalPersona,draft_revision:4};api.updateAdminPersona.mockResolvedValue(saved);const onSaved=vi.fn()
 render(<CoachTeaching persona={originalPersona} lifecycle={simpleLifecycle} onDirtyChange={vi.fn()} onSaved={onSaved}/>);
 fireEvent.change(screen.getByLabelText('Teaching method'),{target:{value:'Choose a comfortable step.'}})
 fireEvent.click(screen.getByRole('button',{name:'Save and preview answers'}))
 await waitFor(()=>expect(onSaved).toHaveBeenCalledWith(saved))
 expect(api.updateAdminPersona).toHaveBeenCalledWith(8,{draft_revision:3,draft_config:{...originalPersona.draft,coaching:{...originalPersona.draft!.coaching,method:'Choose a comfortable step.'}}})
 expect(simpleLifecycle.finish).toHaveBeenCalled()
})
it('keeps a failed edit available without publishing or discarding it',async()=>{
 api.updateAdminPersona.mockRejectedValue(new Error('conflict'))
 render(<CoachTeaching persona={originalPersona} lifecycle={simpleLifecycle} onDirtyChange={vi.fn()} onSaved={vi.fn()}/>);
 fireEvent.change(screen.getByLabelText('Teaching method'),{target:{value:'Choose a comfortable step.'}});fireEvent.click(screen.getByRole('button',{name:'Save and preview answers'}));
 await screen.findByRole('alert');expect(screen.getByLabelText('Teaching method')).toHaveProperty('value','Choose a comfortable step.')
})
it('does not carry a late response into a different program',async()=>{
 api.updateAdminPersona.mockImplementation(async()=>{simpleLifecycle.isCurrent.mockReturnValue(false);return originalPersona});const onSaved=vi.fn()
 render(<CoachTeaching persona={originalPersona} lifecycle={simpleLifecycle} onDirtyChange={vi.fn()} onSaved={onSaved}/>);
 fireEvent.change(screen.getByLabelText('Teaching method'),{target:{value:'Choose a comfortable step.'}});fireEvent.click(screen.getByRole('button',{name:'Save and preview answers'}));
 await waitFor(()=>expect(simpleLifecycle.finish).toHaveBeenCalled());expect(onSaved).not.toHaveBeenCalled()
})
