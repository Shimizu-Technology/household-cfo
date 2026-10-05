// @vitest-environment jsdom
import {afterEach,beforeEach,expect,it,vi} from 'vitest'
import {clearEvidenceIdentity,evidenceRecoveryStorage,readEvidenceIdentity,saveEvidenceIdentity} from './evidenceRecovery'
import {baselineScope} from '../test/baselineFixtures'
const scope={...baselineScope,enrollment_id:7,entry_version_id:11}
const original={scope,action:'attach' as const,key:'original'}
beforeEach(()=>sessionStorage.clear())
afterEach(()=>vi.restoreAllMocks())
it('cannot overwrite an unresolved same-scope key or action and retains other scopes',()=>{
 const b={...original,scope:{...scope,enrollment_id:8},key:'other-program'}
 expect(saveEvidenceIdentity(original)).toBe(true);expect(saveEvidenceIdentity(b)).toBe(true)
 const saved=sessionStorage.getItem(evidenceRecoveryStorage)
 expect(saveEvidenceIdentity({...original,key:'duplicate'})).toBe(false)
 expect(saveEvidenceIdentity({...original,action:'revoke'})).toBe(false)
 expect(sessionStorage.getItem(evidenceRecoveryStorage)).toBe(saved)
 expect(readEvidenceIdentity(scope)).toEqual(original);expect(readEvidenceIdentity(b.scope)).toEqual(b)
 clearEvidenceIdentity({...original,key:'foreign'});expect(readEvidenceIdentity(scope)).toEqual(original)
 clearEvidenceIdentity(original);expect(readEvidenceIdentity(scope)).toBeNull();expect(readEvidenceIdentity(b.scope)).toEqual(b)
})
it('stores only routing metadata and keeps exact same-key retries writable',()=>{
 expect(saveEvidenceIdentity({...original,scope:{...scope,financial_label:'Never persist'},input:{proofs:[{amount_cents:13337}],reason:'Never persist'}} as Parameters<typeof saveEvidenceIdentity>[0])).toBe(true)
 expect(sessionStorage.getItem(evidenceRecoveryStorage)).not.toContain('Never persist');expect(sessionStorage.getItem(evidenceRecoveryStorage)).not.toContain('13337')
 expect(saveEvidenceIdentity(original)).toBe(true)
})
it.each(['quota','disabled','silently ignored'])('does not report a new identity retained when storage is %s',mode=>{
 if(mode==='disabled')vi.spyOn(Storage.prototype,'getItem').mockImplementation(()=>{throw new DOMException('Disabled','SecurityError')})
 else vi.spyOn(Storage.prototype,'setItem').mockImplementation(()=>{if(mode==='quota')throw new DOMException('Quota','QuotaExceededError')})
 expect(saveEvidenceIdentity(original)).toBe(false)
})
