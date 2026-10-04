import {useCallback,useEffect,useRef,useState} from 'react'
import {ApiRequestError} from '../api'
import {fetchParticipantPrograms,type ParticipantPrograms,type ParticipantProgram} from '../participantProgramsApi'
import './ParticipantProgramPicker.css'
type Props={actorId:number;currentCohortId?:number;onChoose:(cohortId:number)=>void}
const statusLabel:Record<ParticipantProgram['status'],string>={draft:'Preparing',enrolling:'Enrolling',active:'Active',completed:'Completed',archived:'Archived'}
export function ParticipantProgramPicker(props:Props){return <ParticipantProgramPickerBody key={props.actorId} {...props}/>}
function ParticipantProgramPickerBody({actorId,currentCohortId,onChoose}:Props){
 const[data,setData]=useState<ParticipantPrograms|null>(null),[loading,setLoading]=useState(true),[error,setError]=useState<string|null>(null),[attempt,setAttempt]=useState(0)
 const active=useRef(false),epoch=useRef(0),controllers=useRef(new Set<AbortController>())
 const invalidate=useCallback(()=>{epoch.current++},[])
 useEffect(()=>{active.current=true;const owned=controllers.current;return()=>{active.current=false;invalidate();for(const controller of owned)controller.abort();owned.clear()}},[invalidate])
 useEffect(()=>{const generation=++epoch.current,controller=new AbortController(),owned=controllers.current;owned.add(controller);queueMicrotask(()=>{if(active.current&&generation===epoch.current){setData(null);setLoading(true);setError(null)}})
  void fetchParticipantPrograms(null,controller.signal).then(next=>{if(!active.current||generation!==epoch.current)return;if(next.actor_id!==actorId)throw new ApiRequestError('Program choices belong to a different account. Refresh your session.',{status:403});setData(next)}).catch(failure=>{if(active.current&&generation===epoch.current){setData(null);setError(failure instanceof Error?failure.message:'Program choices are unavailable.')}}).finally(()=>{controllers.current.delete(controller);if(active.current&&generation===epoch.current)setLoading(false)})
  return()=>{invalidate();for(const request of owned)request.abort();owned.clear()}
 },[actorId,currentCohortId,attempt,invalidate])
 async function more(){if(!data?.next_cursor||loading)return;const current=data,generation=++epoch.current,controller=new AbortController();controllers.current.add(controller);setLoading(true);setError(null)
  try{const next=await fetchParticipantPrograms(current.next_cursor,controller.signal);if(!active.current||generation!==epoch.current)return;if(next.actor_id!==actorId)throw new ApiRequestError('Program choices belong to a different account. Refresh your session.',{status:403});if(next.current_cohort_id!==current.current_cohort_id||next.selection_unavailable!==current.selection_unavailable)throw new Error('Your current program changed. Refresh before switching.');setData({...next,programs:[...current.programs,...next.programs]})}catch(failure){if(!active.current||generation!==epoch.current)return;if(failure instanceof ApiRequestError&&[401,403,422].includes(failure.status))setData(null);setError(failure instanceof Error?failure.message:'More program choices are unavailable.')}finally{controllers.current.delete(controller);if(active.current&&generation===epoch.current)setLoading(false)}
 }
 const choices=data?[...data.programs,...(data.current_program&&!data.programs.some(row=>row.id===data.current_program!.id)?[data.current_program]:[])]:[]
 const explicit=currentCohortId===undefined?data?.current_cohort_id??null:currentCohortId
 const selected=choices.find(row=>row.id===explicit),unavailable=Boolean(data?.selection_unavailable||(currentCohortId!==undefined&&data&&!selected&&data.next_cursor===null))
 function choose(id:number){if(!active.current||loading||error||!choices.some(row=>row.id===id))return;onChoose(id)}
 return <section className="participant-program-picker" aria-label="Your participant programs"><h2>Your program</h2>{loading&&<p role="status">{data?'Loading more programs…':'Checking your program choices…'}</p>}{error&&<p role="alert">{error} Refresh before choosing a program.</p>}{(error||unavailable)&&<button type="button" disabled={loading} onClick={()=>setAttempt(value=>value+1)}>Retry program choices</button>}{unavailable&&<p role="status">The selected program is unavailable for this account in this workspace. Choose a listed program or retry.</p>}
  {data&&!error&&<><button type="button" disabled={loading} onClick={()=>setAttempt(value=>value+1)}>Refresh program choices</button>{choices.length===0?<p>No participant programs are available in this workspace.</p>:choices.length===1&&!data.next_cursor?<><p><strong>{choices[0].name}</strong> · {statusLabel[choices[0].status]}</p>{(!selected||unavailable)&&<button type="button" disabled={loading} onClick={()=>choose(choices[0].id)}>Use {choices[0].name}</button>}</>:<label>Switch participant program<select value={selected&&!unavailable?selected.id:''} disabled={loading} onChange={event=>choose(Number(event.target.value))}><option value="" disabled>Choose one of your programs</option>{choices.map(row=><option key={row.id} value={row.id}>{row.name} · {statusLabel[row.status]}</option>)}</select></label>}
  {selected&&['draft','archived'].includes(selected.status)&&<p>This program is {statusLabel[selected.status].toLowerCase()}. Its tools may be unavailable; selecting a program does not grant access.</p>}{data.next_cursor!==null&&<><p>More participant programs are available.</p><button type="button" disabled={loading} onClick={()=>void more()}>Load more programs</button></>}
  {choices.length>0&&<p className="program-picker-note">Switching changes the workspace you view. It does not join a program or accept participation terms.</p>}</>}
 </section>
}
