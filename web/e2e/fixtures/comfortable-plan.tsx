import React, {useState} from 'react'
import {createRoot} from 'react-dom/client'
import {SavingsChallengeHome} from '../../src/components/SavingsChallengeHome'
import {savingsFixture,savingsPlanDraft,savingsPlanVersion} from '../../src/test/savingsFixtures'
import {baselineCurrent,baselinePreview,baselineRequest,baselineScope,baselineVersion} from '../../src/test/baselineFixtures'
import type {SavingsPlanDraft,SavingsPlanContextInput} from '../../src/lib/savingsChallenge'
import '../../src/index.css'
import '../../src/App.css'
const scope=baselineScope
const challenge=savingsFixture();challenge.accepted_plan={...savingsPlanVersion(25000),financial_baseline_version_id:null,baseline_digest:null,spending_changes:[]};challenge.enrollment!.current_accepted_plan_version_id=21;challenge.projection!.target_cents=25000
const source=baselineRequest();source.category_eligibility=[{budget_category_id:10,eligible:true,recurrence:'unknown',reason:'Participant considered groceries'}]
const version=baselineVersion(baselinePreview(source,true));version.digest='a'.repeat(64);version.preview.category_eligibility.push({budget_category_id:20,name:'Dining',active:true,eligible:false,recurrence:'recurring',reason:'Protect essentials'})
let baseline=baselineCurrent(version),uncertain=false,revoked=false
const drafts:SavingsPlanDraft[]=[];const journal=new Map<string,object>();const calls:Array<{key:string;path:string;input:Record<string,unknown>}>=[]
const response=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json'}})
window.fetch=async(input,options)=>{
 const path=new URL(typeof input==='string'?input:input instanceof URL?input.href:input.url).pathname
 if(revoked)return response({errors:['Synthetic private access revoked.']},403)
 if(path.endsWith('/financial_baseline'))return response(baseline)
 if(path.endsWith('/request_status')){const key=new Headers(options?.headers).get('Idempotency-Key')!;return response(journal.has(key)?{...journal.get(key),state:'committed',replayed:true,actor_scope:scope}:{state:'unknown',can_retry:true,actor_scope:scope})}
 if((options?.method??'GET')==='GET'){
  if(path.endsWith('/savings_challenge'))return response(challenge)
  const records=path.endsWith('/plan_drafts')?drafts:[];const cursor=Number(new URL(String(input)).searchParams.get('cursor')??0)
  return response({records:records.filter(row=>row.id>cursor).slice(0,10),next_cursor:null,actor_scope:scope,enrollment_id:1,cohort_id:42})
 }
 const key=new Headers(options?.headers).get('Idempotency-Key')!;const values=JSON.parse(String(options?.body)) as Record<string,unknown>;calls.push({key,path,input:values});window.dispatchEvent(new Event('qa-request'))
 if(journal.has(key))return response({...journal.get(key),replayed:true})
 let record:unknown
 if(path.endsWith('/plan_drafts')){
  const context=values as unknown as SavingsPlanContextInput
  const draft={...savingsPlanDraft(Number(values.target_cents)),id:11+drafts.length,target_cents:values.target_cents as number|null,base_plan_version_id:values.expected_plan_version_id as number|null,reason:String(values.reason??''),...context,spending_changes:context.spending_changes?.map(row=>({...row,category_name:row.budget_category_id===10?'Groceries':null})),baseline_context:context.financial_baseline_version_id?{window_start_on:'2026-09-01',window_end_on:'2026-09-30',coverage_status:'partial' as const}:null}
  drafts.push(draft);challenge.pending_plan_count=drafts.filter(row=>row.status==='pending').length;record=draft
 }else if(path.endsWith('/approve')){
  const draft=drafts.find(row=>row.id===Number(path.split('/').at(-2)))!
  if(draft.financial_baseline_version_id&&baseline.needs_revision)return response({errors:['Approved baseline changed. Refresh the current context.']},409)
  challenge.accepted_plan={...savingsPlanVersion(draft.target_cents??50000),...draft,id:22,previous_version_id:21};challenge.enrollment!.current_accepted_plan_version_id=22;challenge.projection!.target_cents=draft.target_cents;draft.status='approved';challenge.pending_plan_count=0;record=challenge.accepted_plan
 }else return response({errors:['Unsupported synthetic action']},422)
 const result=structuredClone({record,replayed:false,challenge});journal.set(key,result)
 if(uncertain){uncertain=false;throw new TypeError('Synthetic interrupted response after commit')}
 return response(result)
}
export function Fixture(){const[visible,setVisible]=useState(true);const[count,setCount]=useState(0);React.useEffect(()=>{const update=()=>setCount(calls.length);window.addEventListener('qa-request',update);return()=>window.removeEventListener('qa-request',update)},[])
 return <main style={{padding:'16px',maxWidth:1200,margin:'auto'}}><p>Fictional local component fixture. No production authentication, real statements, or money movement.</p><details><summary>Synthetic QA controls</summary><button onClick={()=>{uncertain=true}}>Interrupt next plan response</button><button onClick={()=>{baseline={...baseline,needs_revision:true};window.dispatchEvent(new Event('focus'))}}>Mark baseline stale</button><button onClick={()=>{revoked=true;window.dispatchEvent(new Event('focus'))}}>Revoke private access</button><button onClick={()=>setVisible(value=>!value)}>{visible?'Hide Home':'Show Home'}</button><output aria-label="Synthetic mutation count">{count}</output></details>{visible&&<SavingsChallengeHome participantScope={scope} onAskMia={()=>undefined} onReviewStatements={()=>undefined}/>}</main>
}
const fixtureRoot = createRoot(document.getElementById('root')!)
fixtureRoot.render(<Fixture/>)
if (import.meta.hot) import.meta.hot.dispose(() => fixtureRoot.unmount())
