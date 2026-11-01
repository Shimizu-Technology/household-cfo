// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { CoachTeaching } from './CoachTeaching'
import type { AdminPersonaDetail } from '../api'
const api=vi.hoisted(()=>({updateAdminPersona:vi.fn()}))
vi.mock('../api',()=>api)
const persona={id:8,draft_revision:3,permissions:{edit:true},draft:{coaching:{method:'Choose a manageable step.',do_not:['Never shame.']},guardrails:{locked:true}}} as unknown as AdminPersonaDetail
const lifecycle={pending:false,begin:vi.fn(()=>({id:1,workspaceId:2})),isCurrent:vi.fn(()=>true),finish:vi.fn()}
beforeEach(()=>{vi.clearAllMocks();lifecycle.isCurrent.mockReturnValue(true)})
afterEach(cleanup)
it('saves only the teaching edit at the reviewed revision and hands the saved assistant to preview',async()=>{
 const saved={...persona,draft_revision:4};api.updateAdminPersona.mockResolvedValue(saved);const onSaved=vi.fn()
 render(<CoachTeaching persona={persona} lifecycle={lifecycle} onDirtyChange={vi.fn()} onSaved={onSaved}/>);
 fireEvent.change(screen.getByLabelText('Teaching method'),{target:{value:'Choose a comfortable step.'}})
 fireEvent.click(screen.getByRole('button',{name:'Save and preview answers'}))
 await waitFor(()=>expect(onSaved).toHaveBeenCalledWith(saved))
 expect(api.updateAdminPersona).toHaveBeenCalledWith(8,{draft_revision:3,draft_config:{...persona.draft,coaching:{...persona.draft!.coaching,method:'Choose a comfortable step.'}}})
 expect(lifecycle.finish).toHaveBeenCalled()
})
it('keeps a failed edit available without publishing or discarding it',async()=>{
 api.updateAdminPersona.mockRejectedValue(new Error('conflict'))
 render(<CoachTeaching persona={persona} lifecycle={lifecycle} onDirtyChange={vi.fn()} onSaved={vi.fn()}/>);
 fireEvent.change(screen.getByLabelText('Teaching method'),{target:{value:'Choose a comfortable step.'}});fireEvent.click(screen.getByRole('button',{name:'Save and preview answers'}));
 await screen.findByRole('alert');expect(screen.getByLabelText('Teaching method')).toHaveProperty('value','Choose a comfortable step.')
})
it('does not carry a late response into a different program',async()=>{
 api.updateAdminPersona.mockImplementation(async()=>{lifecycle.isCurrent.mockReturnValue(false);return persona});const onSaved=vi.fn()
 render(<CoachTeaching persona={persona} lifecycle={lifecycle} onDirtyChange={vi.fn()} onSaved={onSaved}/>);
 fireEvent.change(screen.getByLabelText('Teaching method'),{target:{value:'Choose a comfortable step.'}});fireEvent.click(screen.getByRole('button',{name:'Save and preview answers'}));
 await waitFor(()=>expect(lifecycle.finish).toHaveBeenCalled());expect(onSaved).not.toHaveBeenCalled()
})
