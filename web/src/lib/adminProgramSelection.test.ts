// @vitest-environment jsdom
import { beforeEach, expect, it } from 'vitest'
import type { CurrentUser } from '../api'
import { rememberAdminProgram, restoredAdminProgram } from './adminProgramSelection'
const admin = {id:1,clerk_id:'admin-one',is_admin:true,coach_workspaces:[{id:2}]} as CurrentUser
beforeEach(()=>localStorage.clear())
it('scopes remembered programs to the verified user and validates current access',()=>{
 rememberAdminProgram(admin,2)
 expect(restoredAdminProgram(admin)).toBe(2)
 expect(restoredAdminProgram({...admin,id:3,clerk_id:'admin-two'})).toBeNull()
 expect(restoredAdminProgram({...admin,coach_workspaces:[]})).toBeNull()
 expect(restoredAdminProgram(admin)).toBeNull()
})
it('remembers All workspaces and leaves non-admin defaults to the server',()=>{
 rememberAdminProgram(admin,null)
 expect(restoredAdminProgram({...admin,active_coach_workspace:{id:2}} as CurrentUser)).toBeNull()
 expect(restoredAdminProgram({...admin,is_admin:false,active_coach_workspace:{id:2}} as CurrentUser)).toBe(2)
})
it('remembers a newly created program while access is revalidated against the refreshed list on reload',()=>{
 rememberAdminProgram(admin,7)
 expect(restoredAdminProgram({...admin,coach_workspaces:[{id:2},{id:7}]} as CurrentUser)).toBe(7)
 expect(restoredAdminProgram({...admin,coach_workspaces:[]})).toBeNull()
})
