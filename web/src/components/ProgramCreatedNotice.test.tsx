// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { ProgramCreatedNotice, rememberCreatedProgram } from './ProgramCreatedNotice'
beforeEach(()=>sessionStorage.clear())
afterEach(()=>{cleanup();vi.restoreAllMocks()})
it('keeps a saved confirmation through the entire staff app remount',()=>{
 const first=render(<ProgramCreatedNotice userId={4} workspaceId={2}/>)
 rememberCreatedProgram(4,{id:7,name:'Mrs. Mel’s new program'})
 first.unmount()
 render(<ProgramCreatedNotice userId={4} workspaceId={7}/>)
 expect(screen.getByRole('status').textContent).toContain('Mrs. Mel’s new program was created and selected')
})
it.each([[5,7],[4,2]])('does not show another account or program’s confirmation', (userId,workspaceId)=>{
 rememberCreatedProgram(4,{id:7,name:'Private program'})
 render(<ProgramCreatedNotice userId={userId} workspaceId={workspaceId}/>)
 expect(screen.queryByRole('status')).toBeNull()
})
it('expires old confirmations and handles unavailable session storage',()=>{
 rememberCreatedProgram(4,{id:7,name:'Old program'})
 vi.spyOn(Date,'now').mockReturnValue(Date.now()+600_001)
 const view=render(<ProgramCreatedNotice userId={4} workspaceId={7}/>)
 expect(screen.queryByRole('status')).toBeNull();view.unmount()
 vi.spyOn(Storage.prototype,'getItem').mockImplementation(()=>{throw new Error('Unavailable')})
 render(<ProgramCreatedNotice userId={4} workspaceId={7}/>)
 expect(screen.queryByRole('status')).toBeNull()
})
