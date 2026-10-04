import React, { useState } from 'react'
import { createRoot } from 'react-dom/client'
import { SavingsChallengeHome } from '../../src/components/SavingsChallengeHome'
import { savingsFixture, savingsEntryDraft, savingsEntryVersion } from '../../src/test/savingsFixtures'
import { saveHomeSavingsIdentity, type HomeSavingsAction } from '../../src/lib/homeSavingsRecovery'
import '../../src/index.css'
import '../../src/App.css'
const params=new URLSearchParams(location.search), actor={user_id:7,household_id:8}, scope={...actor,cohort_id:42}
let enrolled=params.get('mode')!=='enrollment', challenge={...savingsFixture(enrolled),cohort_id:42}, interrupted=false, statusInFlight=false, wrongScope=false, lateConflict=false
const entry={id:41,current_approved_version_id:51,lock_version:2,current_approved_version:savingsEntryVersion()}
const drafts=params.get('pending')==='entry_approve'?[savingsEntryDraft(),{...savingsEntryDraft(),id:32}]:[]
let holdRead=false,releaseRead:(()=>void)|null=null
const journal=new Map<string,object>(), calls:Array<{key:string;action:string}>=[]
const action=params.get('pending')as HomeSavingsAction|null
if(action&&!sessionStorage.getItem('savings-home-request-identities-v1'))saveHomeSavingsIdentity({scope,action,key:'fictional-original-key',enrollmentId:action==='enrollment'?null:1,...(action==='entry_approve'?{draftId:31}:{}),...(params.get('correction')?{entryId:41}:{})})
const response=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json'}})
window.fetch=async(input,options)=>{
 const url=new URL(typeof input==='string'?input:input instanceof URL?input.href:input.url), path=url.pathname, key=new Headers(options?.headers).get('Idempotency-Key')??''
 if(path.endsWith('/request_status'))return response(statusInFlight?{state:'in_flight',actor_scope:actor,cohort_id:42}:journal.has(key)?{...journal.get(key),state:'committed',replayed:true,actor_scope:actor,cohort_id:42}:{state:'unknown',can_retry:true,actor_scope:actor,cohort_id:wrongScope?99:42},statusInFlight?202:200)
 if((options?.method??'GET')==='GET'){
  if(path.endsWith('/savings_challenge')){if(holdRead){holdRead=false;const captured=structuredClone(challenge);return new Promise<Response>(resolve=>{releaseRead=()=>resolve(response(captured))})}return response(challenge)}
  const records=path.endsWith('/entry_drafts')?drafts:path.endsWith('/entries')?[entry,{...entry,id:42}]:[];const cursor=Number(url.searchParams.get('cursor')??0)
  return response({records:records.filter(row=>row.id>cursor).slice(0,10),next_cursor:null,actor_scope:actor,enrollment_id:1,cohort_id:42})
 }
 const values=JSON.parse(String(options?.body))as Record<string,unknown>;calls.push({key,action:path.split('/').at(-1)!});window.dispatchEvent(new Event('qa-request'))
 if(lateConflict){lateConflict=false;const result={record:savingsEntryDraft(),replayed:false,challenge};journal.set(key,structuredClone(result));return response({errors:['Earlier original request committed. Check its result.']},409)}
 if(journal.has(key))return response({...journal.get(key),replayed:true})
 let record:unknown
 if(path.endsWith('/enrollment')){enrolled=true;challenge={...savingsFixture(),cohort_id:42};record=challenge.enrollment}
 else if(path.endsWith('/entry_drafts')){const draft={...savingsEntryDraft(Number(values.signed_cents)),id:31+drafts.length,effective_on:String(values.effective_on),funding_source:values.funding_source as typeof drafts[number]['funding_source'],reason:String(values.reason??'')};drafts.push(draft);challenge.pending_entry_count=drafts.filter(row=>row.status==='pending').length;record=draft}
 else if(path.endsWith('/approve')){const draft=drafts.find(row=>row.id===Number(path.split('/').at(-2)))!;draft.status='approved';record=savingsEntryVersion(draft.signed_cents);challenge.projection={...challenge.projection!,reporting_known:true,reported_cents:draft.signed_cents,evidence_supported_cents:0};challenge.pending_entry_count=drafts.filter(row=>row.status==='pending').length}
 else if(path.endsWith('/zero_attestations')){record={id:2};challenge.projection={...challenge.projection!,reporting_known:true,reported_cents:0,evidence_supported_cents:0,zero_attested:true}}
 else return response({errors:['Unsupported synthetic action']},422)
 const result=structuredClone({record,replayed:false,challenge});journal.set(key,result);if(interrupted){interrupted=false;throw new TypeError('Fictional lost response after commit')}return response(result)
}
export function Fixture(){const[visible,setVisible]=useState(true),[count,setCount]=useState(0),[token,setToken]=useState(0);React.useEffect(()=>{const update=()=>setCount(calls.length);window.addEventListener('qa-request',update);return()=>window.removeEventListener('qa-request',update)},[])
 return <main style={{padding:16,maxWidth:1200,margin:'auto'}}><p>Fictional local Home recovery fixture. No real statements, authentication, or money movement.</p><details open><summary>Synthetic QA controls</summary><button onClick={()=>{interrupted=true}}>Interrupt next response</button><button onClick={()=>setVisible(value=>!value)}>{visible?'Hide Home':'Show Home'}</button><button onClick={()=>{statusInFlight=!statusInFlight}}>Toggle in-flight status</button><button onClick={()=>{wrongScope=true}}>Return wrong program</button><button onClick={()=>{lateConflict=true}}>Original wins fresh-review race</button><button onClick={()=>{challenge.projection={...challenge.projection!,reporting_known:true,reported_cents:2550,evidence_supported_cents:1000};setToken(value=>value+1)}}>Refresh synthetic evidence</button><button onClick={()=>{holdRead=true;window.dispatchEvent(new Event('focus'))}}>Hold next Home read</button><button onClick={()=>{releaseRead?.();releaseRead=null}}>Release held Home read</button><output aria-label="Synthetic mutation count">{count}</output><output aria-label="Last synthetic request key">{calls.at(-1)?.key??'None'}</output></details>{visible&&<SavingsChallengeHome cohortId={42} participantScope={actor} evidenceRefreshToken={token} onAskMia={()=>undefined} onReviewStatements={()=>undefined} onToday={()=>undefined}/>}</main>
}
const root=createRoot(document.getElementById('root')!);root.render(<Fixture/>);if(import.meta.hot)import.meta.hot.dispose(()=>root.unmount())
