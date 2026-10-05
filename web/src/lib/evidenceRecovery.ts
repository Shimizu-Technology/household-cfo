import { retainRequestIdentity } from './durableRequestIdentity'
import type { EvidenceAction, EvidenceScope } from './savingsEvidence'
export const evidenceRecoveryStorage='savings-evidence-request-identities-v1'
export type EvidenceIdentity={scope:EvidenceScope;action:EvidenceAction;key:string}
const identity=(scope:EvidenceScope)=>`${scope.user_id}:${scope.household_id}:${scope.enrollment_id}:${scope.entry_version_id}`
function values():Record<string,EvidenceIdentity>{const value:unknown=JSON.parse(sessionStorage.getItem(evidenceRecoveryStorage)??'{}');return value&&typeof value==='object'&&!Array.isArray(value)?value as Record<string,EvidenceIdentity>:{} }
export function readEvidenceIdentity(scope:EvidenceScope):EvidenceIdentity|null{try{const saved=values()[identity(scope)];if(saved&&['attach','revoke'].includes(saved.action)&&typeof saved.key==='string'&&saved.key.length>0&&saved.scope&&identity(saved.scope)===identity(scope))return {scope,action:saved.action,key:saved.key}}catch{/* Invalid storage cannot recreate financial inputs. */}return null}
export function saveEvidenceIdentity(request:EvidenceIdentity){
 try{
  const records=values(),key=identity(request.scope),existing=records[key]
  if(existing&&(existing.key!==request.key||existing.action!==request.action||!existing.scope||identity(existing.scope)!==key))return false
  records[key]={scope:{user_id:request.scope.user_id,household_id:request.scope.household_id,enrollment_id:request.scope.enrollment_id,entry_version_id:request.scope.entry_version_id},action:request.action,key:request.key}
  return retainRequestIdentity(evidenceRecoveryStorage,JSON.stringify(records))
 }catch{return false}
}
export function clearEvidenceIdentity(request:EvidenceIdentity){try{const records=values();if(records[identity(request.scope)]?.key===request.key)delete records[identity(request.scope)];if(Object.keys(records).length)sessionStorage.setItem(evidenceRecoveryStorage,JSON.stringify(records));else sessionStorage.removeItem(evidenceRecoveryStorage)}catch{/* Storage unavailable. */}}
