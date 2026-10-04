import {describe,expect,it} from 'vitest'
import {miaWorkspaceStorageKey} from './miaWorkspaceScope'
describe('private Mia retry workspace',()=>{
 it('does not restore a saved prompt or attachment from another actor, household, program, workspace or unverified bootstrap',()=>{
  const original=miaWorkspaceStorageKey('mia',7,null,8,42)
  const pending=new Map([[original,{message:'Fictional financial question',documentImportId:99}]])
  for(const key of [miaWorkspaceStorageKey('mia',9,null,8,42),miaWorkspaceStorageKey('mia',7,null,10,42),miaWorkspaceStorageKey('mia',7,null,8,43),miaWorkspaceStorageKey('mia',7,12,8,42),miaWorkspaceStorageKey('mia',7)])expect(pending.get(key)).toBeUndefined()
  expect(pending.get(miaWorkspaceStorageKey('mia',7,null,8,42))?.documentImportId).toBe(99)
 })
})
