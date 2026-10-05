import { retainRequestIdentity } from './durableRequestIdentity'
import type { BaselineScope } from './financialBaseline'
import type { SavingsPlanApproval, SavingsPlanInput } from './savingsChallenge'
export type PlanScope = BaselineScope & { enrollment_id:number }
export type PlanRequest = {scope:PlanScope;action:'plan_stage'|'plan_approve';key:string;input?:SavingsPlanInput|SavingsPlanApproval;draftId?:number;working:boolean;error?:string;unknown?:boolean;awaitingFreshReview?:boolean;recoveryReview?:boolean}
const storage='comfortable-plan-request-identities-v1'
let actor:PlanScope|null=null, pending:PlanRequest|null=null
const listeners=new Set<()=>void>();const notify=()=>listeners.forEach(listener=>listener())
const identity=(scope:PlanScope)=>`${scope.user_id}:${scope.household_id}:${scope.enrollment_id}`
function stored():Record<string,PlanRequest>{const value:unknown=JSON.parse(sessionStorage.getItem(storage)??'{}');return value&&typeof value==='object'&&!Array.isArray(value)?value as Record<string,PlanRequest>:{} }
function remember(){try{const values=stored();if(pending)values[identity(pending.scope)]={scope:{user_id:pending.scope.user_id,household_id:pending.scope.household_id,enrollment_id:pending.scope.enrollment_id},action:pending.action,key:pending.key,draftId:pending.draftId} as PlanRequest;else if(actor)delete values[identity(actor)];if(Object.keys(values).length)return retainRequestIdentity(storage,JSON.stringify(values));sessionStorage.removeItem(storage);return sessionStorage.getItem(storage)===null}catch{return false}}
export function bindPlanScope(scope:PlanScope|null){if((scope?identity(scope):null)===(actor?identity(actor):null))return;actor=scope;pending=null;if(scope){try{const saved=stored()[identity(scope)];if(saved&&typeof saved.key==='string'&&['plan_stage','plan_approve'].includes(saved.action)&&identity(saved.scope)===identity(scope))pending={scope,action:saved.action,key:saved.key,draftId:saved.draftId,working:false,error:'An earlier plan request needs its result checked before further changes.'}}catch{/* Invalid storage cannot recreate a financial request. */}}notify()}
export function isPlanScope(scope:PlanScope){return actor!==null&&identity(scope)===identity(actor)}
export function readPlanRequest(scope:PlanScope|undefined){return scope&&isPlanScope(scope)?pending:null}
export function savePlanRequest(request:PlanRequest){if(!isPlanScope(request.scope))return false;const previous=pending;pending=request;const retained=remember();if(!retained&&previous?.key!==request.key)pending=previous;notify();return retained}
export function clearPlanRequest(key:string){if(pending?.key===key){pending=null;remember();notify()}}
export function subscribePlanRequest(listener:()=>void){listeners.add(listener);return()=>{listeners.delete(listener)}}

export function fencePlanActor(scope:BaselineScope){if(actor&&(scope.user_id!==actor.user_id||scope.household_id!==actor.household_id))bindPlanScope(null)}
