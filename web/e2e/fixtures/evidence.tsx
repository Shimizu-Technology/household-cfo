import {useState} from 'react'
import {createRoot} from 'react-dom/client'
import {SavingsChallengeHome} from '../../src/components/SavingsChallengeHome'
import {savingsFixture} from '../../src/test/savingsFixtures'
import {SavingsEvidenceDialog} from '../../src/components/SavingsEvidenceDialog'
import {evidenceActor,evidenceCandidate,evidencePage,evidenceVersion} from '../../src/test/evidenceFixtures'
import {baselineScope} from '../../src/test/baselineFixtures'
import type {EvidenceMutation} from '../../src/lib/savingsEvidence'
import '../../src/index.css'
import '../../src/App.css'
const scenario=new URLSearchParams(location.search).get('case');let interrupted=false,denied=false,count=0
let current=evidencePage();const journal=new Map<string,EvidenceMutation>()
if(scenario==='history'){current={...current,entry_is_current:false,entry:{...current.entry,evidence_status:'stale'},head:{id:30,current_version_id:31,lock_version:2},current_version:evidenceVersion(),records:[evidenceVersion()]}}
const response=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json'}})
window.fetch=async(input,options)=>{
 const url=new URL(typeof input==='string'?input:input instanceof URL?input.href:input.url);const path=url.pathname;const cursor=Number(url.searchParams.get('cursor')??0);const key=new Headers(options?.headers).get('Idempotency-Key')!
 if(denied)return response({errors:['Synthetic private access revoked']},403)
 if(path.endsWith('/savings_challenge')){const challenge=savingsFixture();challenge.enrollment!.id=7;challenge.projection={...challenge.projection!,reporting_known:true,reported_cents:5000,evidence_supported_cents:0,contribution_cents:5000,withdrawal_cents:0,included_entry_count:1};return response(challenge)}
 if(path.endsWith('/entry_versions'))return response({records:cursor?[current.entry]:[{...current.entry,id:8,funding_source:'borrowed'}],next_cursor:cursor?null:8,...evidenceActor,cohort_id:42})
 if(path.endsWith('/entries'))return response({records:[],next_cursor:null,...evidenceActor,cohort_id:42})
 if(path.endsWith('/plan_drafts')||path.endsWith('/entry_drafts'))return response({records:[],next_cursor:null,...evidenceActor,cohort_id:42})
 if(path.endsWith('/request_status'))return response(journal.has(key)?{...journal.get(key),state:'committed',replayed:true}:{...evidenceActor,state:'unknown',can_retry:true})
 if(path.endsWith('/candidates')){
  const record=evidenceCandidate(cursor?102:101)
  if(scenario==='empty'&&!cursor)return response({...evidenceActor,records:[],next_cursor:50})
  if(scenario==='transfer'){record.movement_kind='reviewed_asset_transfer';record.economic_group_version_id=201;record.expected_group_digest='d'.repeat(64);record.canonical_event_ids=[1101,1102];record.signed_amount_cents=-5000;record.source_available=false;record.merchant='Fictional reserve transfer';record.movement_legs=[{merchant:'Reserve transfer out',posted_on:'2026-10-02',account_label:'Fictional checking',filename:'Fictional-checking.pdf',source_available:false,signed_amount_cents:-5000},{merchant:'Reserve transfer in',posted_on:'2026-10-02',account_label:'Fictional reserves',filename:'Fictional-reserves.pdf',source_available:true,signed_amount_cents:5000}]}
  return response({...evidenceActor,records:[record],next_cursor:cursor?null:50})
 }
 if(path.endsWith('/evidence'))return response({...current,records:cursor?[evidenceVersion()]:current.records,next_cursor:!cursor&&current.records.length?50:null})
 count++;window.dispatchEvent(new Event('evidence-count'))
 if(journal.has(key))return response({...journal.get(key),replayed:true})
 if(scenario==='conflict')return response({errors:['Reviewed source changed. Refresh before approving.']},409)
 if(scenario==='unknown'&&!interrupted){interrupted=true;throw new TypeError('Synthetic response lost before commit')}
 const values=JSON.parse(String(options?.body));const revoked=path.endsWith('/revoke');const version={...evidenceVersion(revoked?'revoked':'attached'),id:31+current.records.length,version_number:current.records.length+1,reason:values.reason,supported_cents:revoked?0:values.proofs.reduce((sum:number,row:{amount_cents:number})=>sum+row.amount_cents,0)}
 current={...current,entry:{...current.entry,evidence_status:revoked?'revoked':'linked',evidence_supported_cents:version.supported_cents},head:{id:30,current_version_id:version.id,lock_version:current.records.length+1},current_version:version,records:[...current.records,version]}
 const result={...evidenceActor,record:version,replayed:false};journal.set(key,result)
 if(scenario==='lost'&&!interrupted){interrupted=true;throw new TypeError('Synthetic interrupted response after commit')}
 return response(result)
}
export function Fixture(){const[open,setOpen]=useState(false);const[changes,setChanges]=useState(0);const[calls,setCalls]=useState(0);const[scope,setScope]=useState(baselineScope)
 return <main style={{padding:16,maxWidth:900,margin:'auto'}}><p>Fictional local component fixture. No real statements, authentication or money movement.</p><h1>Savings evidence preview</h1><p>Reported savings stays $50.00.</p><button onClick={()=>setOpen(true)}>Review fictional savings evidence</button><button onClick={()=>{denied=true;setOpen(true)}}>Revoke fictional private access</button><button onClick={()=>{setScope({user_id:902,household_id:78});setOpen(true)}}>Switch fictional actor</button>{scenario==='history'&&<SavingsChallengeHome participantScope={baselineScope} onAskMia={()=>undefined} onReviewStatements={()=>undefined} onReviewEvidence={()=>setOpen(true)}/>}<output aria-label="Synthetic mutation count">{calls}</output><output aria-label="Synthetic completed changes">{changes}</output>{open&&<SavingsEvidenceDialog actorScope={scope} entryVersionId={11} onClose={()=>{setOpen(false);setCalls(count)}} onChanged={()=>{setChanges(value=>value+1);setCalls(count)}}/>}</main>
}
const root=createRoot(document.getElementById('root')!);root.render(<Fixture/>);if(import.meta.hot)import.meta.hot.dispose(()=>root.unmount())
