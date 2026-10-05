// @vitest-environment jsdom
import {act,cleanup,renderHook,waitFor} from '@testing-library/react'
import {afterEach,beforeEach,expect,it,vi} from 'vitest'
import {fetchSavingsEvidenceStatus,mutateSavingsEvidence} from '../evidenceApi'
import {evidenceActor,evidenceVersion} from '../test/evidenceFixtures'
import {baselineScope} from '../test/baselineFixtures'
import {evidenceRecoveryStorage,readEvidenceIdentity} from './evidenceRecovery'
import {useEvidenceMutation} from './useEvidenceMutation'
import type {EvidenceAction,EvidenceInput} from './savingsEvidence'
vi.mock('../evidenceApi',()=>({fetchSavingsEvidenceStatus:vi.fn(),mutateSavingsEvidence:vi.fn()}))
const scope={...baselineScope,enrollment_id:7,entry_version_id:11}
const input:EvidenceInput={entry_version_id:11,expected_evidence_version_id:null,expected_head_lock_version:0,accepted:true,reason:'Fictional private proof',participant_ownership_accepted:true,new_money_reservation_accepted:true,proofs:[]}
beforeEach(()=>{sessionStorage.clear();vi.resetAllMocks()})
afterEach(()=>{cleanup();vi.restoreAllMocks()})
function denyStorage(mode:string){return mode==='disabled'?vi.spyOn(Storage.prototype,'getItem').mockImplementation(()=>{throw new DOMException('Disabled','SecurityError')}):vi.spyOn(Storage.prototype,'setItem').mockImplementation(()=>{if(mode==='quota')throw new DOMException('Quota','QuotaExceededError')})}
it.each(['quota','disabled','silently ignored'])('does not send a new proof or acknowledge success when storage is %s',async mode=>{
 const done=vi.fn(),hook=renderHook(()=>useEvidenceMutation(scope,done,vi.fn(),vi.fn()));await act(async()=>{})
 const store=denyStorage(mode)
 await act(async()=>{await hook.result.current.submit('attach',input)})
 expect(mutateSavingsEvidence).not.toHaveBeenCalled();expect(done).not.toHaveBeenCalled();expect(hook.result.current.pending).toBeNull();expect(hook.result.current.error).toContain('No proof change was submitted');store.mockRestore()
})
it.each([['attach','quota'],['attach','disabled'],['revoke','quota'],['revoke','disabled']] as const)('keeps uncertain %s locked to its original key after %s storage failure',async(action,mode)=>{
 vi.mocked(mutateSavingsEvidence).mockRejectedValueOnce(new Error('Lost reply')).mockResolvedValueOnce({...evidenceActor,record:evidenceVersion(action==='revoke'?'revoked':'attached'),replayed:true})
 const done=vi.fn(),hook=renderHook(()=>useEvidenceMutation(scope,done,vi.fn(),vi.fn()));await act(async()=>{})
 await act(async()=>{await hook.result.current.submit(action,input)})
 const first=vi.mocked(mutateSavingsEvidence).mock.calls[0],key=first[2],stored=sessionStorage.getItem(evidenceRecoveryStorage)
 expect(stored).toContain(key);expect(stored).not.toContain('Fictional private proof')
 const store=denyStorage(mode)
 await act(async()=>{await hook.result.current.retry?.()})
 expect(mutateSavingsEvidence).toHaveBeenCalledOnce();expect(done).not.toHaveBeenCalled();expect(hook.result.current.pending).toMatchObject({key,action,input,working:false});expect(hook.result.current.error).toContain('No proof change was submitted')
 store.mockRestore()
 for(const other of ['attach','revoke'] as EvidenceAction[])await act(async()=>{await hook.result.current.submit(other,{...input,reason:'Unrelated change'})})
 expect(mutateSavingsEvidence).toHaveBeenCalledOnce();expect(sessionStorage.getItem(evidenceRecoveryStorage)).toBe(stored)
 await act(async()=>{await hook.result.current.retry?.()})
 expect(vi.mocked(mutateSavingsEvidence).mock.calls[1].slice(0,3)).toEqual(first.slice(0,3));expect(done).toHaveBeenCalledOnce();expect(hook.result.current.pending).toBeNull();expect(readEvidenceIdentity(scope)).toBeNull()
})
it('retains cold status reconciliation after quota failure without replaying financial inputs',async()=>{
 vi.mocked(mutateSavingsEvidence).mockRejectedValueOnce(new Error('Lost reply'))
 vi.mocked(fetchSavingsEvidenceStatus).mockResolvedValue({...evidenceActor,state:'committed',record:evidenceVersion(),replayed:true})
 const done=vi.fn(),first=renderHook(()=>useEvidenceMutation(scope,done,vi.fn(),vi.fn()));await act(async()=>{})
 await act(async()=>{await first.result.current.submit('attach',input)})
 const key=first.result.current.pending!.key,store=denyStorage('quota')
 await act(async()=>{await first.result.current.retry?.()});store.mockRestore();first.unmount()
 const cold=renderHook(()=>useEvidenceMutation(scope,done,vi.fn(),vi.fn()));await waitFor(()=>expect(cold.result.current.pending?.key).toBe(key))
 expect(cold.result.current.retry).toBeNull();expect(cold.result.current.pending?.input).toBeUndefined();expect(cold.result.current.reviewFresh).toBeNull()
 await act(async()=>{await cold.result.current.check?.()})
 expect(fetchSavingsEvidenceStatus).toHaveBeenCalledWith('attach',11,key,expect.any(AbortSignal));expect(mutateSavingsEvidence).toHaveBeenCalledOnce();expect(done).toHaveBeenCalledOnce();expect(cold.result.current.pending).toBeNull()
})
