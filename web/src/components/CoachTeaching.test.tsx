// @vitest-environment jsdom
import { useState } from 'react'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { ApiRequestError, type AdminPersonaDetail, type CurrentUser } from '../api'
import { CoachTeaching, CoachTeachingWorkspace } from './CoachTeaching'
import { useCoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'
const api=vi.hoisted(()=>({updateAdminPersona:vi.fn(),createAdminPersonaSetupSession:vi.fn()}))
vi.mock('../api',async original=>({...await original<typeof import('../api')>(),...api}))
vi.mock('./CoachContentLibrary',()=>({CoachContentLibrary:({onDirtyChange,onPersonaChange,selectedPersona}:{onDirtyChange:(dirty:boolean)=>void;onPersonaChange:(persona:AdminPersonaDetail)=>void;selectedPersona:AdminPersonaDetail})=><><label>Library draft<input onChange={event=>onDirtyChange(Boolean(event.target.value))}/></label><button onClick={()=>onPersonaChange({...selectedPersona,draft_revision:selectedPersona.draft_revision!+1})}>Attach library collection</button></>}))
const persona={id:8,draft_revision:1,draft:{coaching:{method:'Ask one question.'}},permissions:{edit:true}} as unknown as AdminPersonaDetail
const dirty=vi.fn(),preview=vi.fn()
function Harness(){const [current,setCurrent]=useState(persona);const lifecycle=useCoachWorkspaceMutationLifecycle(1);return <CoachTeachingWorkspace persona={current} currentUser={{id:902} as CurrentUser} lifecycle={lifecycle} onDirtyChange={dirty} onPersonaChange={setCurrent} onPreview={preview}/>}
beforeEach(()=>{vi.resetAllMocks();api.createAdminPersonaSetupSession.mockResolvedValue({proposal:null});api.updateAdminPersona.mockResolvedValue({...persona,draft_revision:2,draft:{coaching:{method:'Ask a kind question.'}}})})
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

it('offers an exact phrase form when chat is unavailable and saves it for preview',async()=>{
 const saved={...originalPersona,draft_revision:4};api.updateAdminPersona.mockResolvedValue(saved)
 render(<CoachTeaching persona={originalPersona} lifecycle={simpleLifecycle} onDirtyChange={dirty} onSaved={preview}/>)
 fireEvent.click(screen.getByText('Add a phrase in your own words',{selector:'summary'}))
 fireEvent.change(screen.getByLabelText('Phrase'),{target:{value:'Chelu, pump the brakes.'}})
 fireEvent.click(screen.getByRole('button',{name:'Save and preview answers'}))
 await waitFor(()=>expect(api.updateAdminPersona).toHaveBeenCalled())
 const phrase=api.updateAdminPersona.mock.calls[0][1].draft_config.phrases[0]
 expect(phrase.text).toBe('Chelu, pump the brakes.');expect(phrase.meaning).toBe(phrase.text)
 expect(phrase.prohibited_contexts).toEqual(['crisis']);expect(preview).toHaveBeenCalledWith(saved)
})

it('R4 warns before a Teaching save destroys pending suggestions and preserves both when declined',async()=>{
 api.updateAdminPersona.mockRejectedValueOnce(new ApiRequestError('Pending suggestions need review.',{status:422,code:'persona_pending_suggestions'}))
 const confirm=vi.spyOn(window,'confirm').mockReturnValue(false)
 render(<CoachTeaching persona={originalPersona} lifecycle={simpleLifecycle} onDirtyChange={vi.fn()} onSaved={preview}/>)
 fireEvent.change(screen.getByLabelText('Teaching method'),{target:{value:'A revised teaching method'}})
 fireEvent.click(screen.getByRole('button',{name:'Save and preview answers'}))
 await waitFor(()=>expect(confirm).toHaveBeenCalledWith(expect.stringContaining('pending voice suggestions')))
 expect(api.updateAdminPersona).toHaveBeenCalledTimes(1);expect(preview).not.toHaveBeenCalled()
 expect(screen.getByLabelText('Teaching method')).toHaveProperty('value','A revised teaching method')
 confirm.mockReturnValue(true)
 api.updateAdminPersona.mockRejectedValueOnce(new ApiRequestError('Pending suggestions need review.',{status:422,code:'persona_pending_suggestions'})).mockResolvedValueOnce(originalPersona)
 fireEvent.click(screen.getByRole('button',{name:'Save and preview answers'}))
 await waitFor(()=>expect(api.updateAdminPersona).toHaveBeenCalledTimes(3))
 expect(api.updateAdminPersona.mock.calls[2][1].discard_pending_suggestions).toBe(true)
 expect(confirm).toHaveBeenCalledTimes(2)
})
it('R13 shows the server safety reason for a refused Teaching save',async()=>{
 api.updateAdminPersona.mockRejectedValue(new ApiRequestError('$.coaching.method contains a regional or cultural stereotype',{status:422}))
 render(<CoachTeaching persona={originalPersona} lifecycle={simpleLifecycle} onDirtyChange={vi.fn()} onSaved={vi.fn()}/>)
 fireEvent.change(screen.getByLabelText('Teaching method'),{target:{value:'Unsafe wording'}})
 fireEvent.click(screen.getByRole('button',{name:'Save and preview answers'}))
 expect((await screen.findByRole('alert')).textContent).toBe('This description could stereotype a group of people. Describe your own coaching approach.')
})

it('CR18 asks before discarding another coaches pending suggestions after an atomic server refusal',async()=>{
 api.updateAdminPersona.mockRejectedValueOnce(new ApiRequestError('Pending suggestions need review.',{status:422,code:'persona_pending_suggestions'})).mockResolvedValueOnce(originalPersona)
 const confirm=vi.spyOn(window,'confirm').mockReturnValue(true)
 render(<CoachTeaching persona={originalPersona} lifecycle={simpleLifecycle} onDirtyChange={vi.fn()} onSaved={vi.fn()}/>)
 fireEvent.change(screen.getByLabelText('Teaching method'),{target:{value:'A changed method'}});fireEvent.click(screen.getByRole('button',{name:'Save and preview answers'}))
 await waitFor(()=>expect(api.updateAdminPersona).toHaveBeenCalledTimes(2))
 expect(confirm).toHaveBeenCalledWith(expect.stringContaining('another coach'))
 expect(api.updateAdminPersona.mock.calls[1][1].discard_pending_suggestions).toBe(true)
})

it('review two saves Teaching while the setup chat endpoint is unavailable',async()=>{
 api.createAdminPersonaSetupSession.mockRejectedValue(new Error('Chat unavailable'))
 render(<CoachTeaching persona={originalPersona} lifecycle={simpleLifecycle} onDirtyChange={vi.fn()} onSaved={preview}/>)
 fireEvent.change(screen.getByLabelText('Teaching method'),{target:{value:'A saved teaching method'}})
 fireEvent.click(screen.getByRole('button',{name:'Save and preview answers'}))
 await waitFor(()=>expect(preview).toHaveBeenCalled())
 expect(api.updateAdminPersona).toHaveBeenCalledWith(8,expect.objectContaining({draft_config:expect.objectContaining({coaching:expect.objectContaining({method:'A saved teaching method'})})}))
 expect(api.createAdminPersonaSetupSession).not.toHaveBeenCalled()
})

it('W23 saves the meaning and situation with an explicit often choice',async()=>{
 render(<CoachTeaching persona={originalPersona} lifecycle={simpleLifecycle} onDirtyChange={dirty} onSaved={preview}/>)
 fireEvent.click(screen.getByText('Add a phrase in your own words',{selector:'summary'}))
 fireEvent.change(screen.getByLabelText('Phrase'),{target:{value:'Chelu, pump the brakes.'}})
 fireEvent.change(screen.getByLabelText('What it means and when to use it (optional)'),{target:{value:'When someone is about to spend money they do not have'}})
 fireEvent.change(screen.getByLabelText('How often'),{target:{value:'as_needed'}})
 fireEvent.click(screen.getByRole('button',{name:'Save and preview answers'}))
 await waitFor(()=>expect(api.updateAdminPersona).toHaveBeenCalled())
 expect(api.updateAdminPersona.mock.calls[0][1].draft_config.phrases[0]).toEqual(expect.objectContaining({meaning:'When someone is about to spend money they do not have',frequency:'as_needed',prohibited_contexts:['crisis']}))
})
