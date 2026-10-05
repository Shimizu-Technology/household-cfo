import { fetchPrivateJson } from './api'
export type ParticipantProgram = { id: number; name: string; status: 'draft' | 'enrolling' | 'active' | 'completed' | 'archived' }
export type ParticipantPrograms = { actor_id: number; current_cohort_id: number | null; current_program: ParticipantProgram | null; selection_unavailable: boolean; programs: ParticipantProgram[]; next_cursor: number | null }
const validId=(value:unknown):value is number=>typeof value==='number'&&Number.isSafeInteger(value)&&value>0
function program(value:ParticipantProgram){return value&&validId(value.id)&&typeof value.name==='string'&&value.name.trim().length>0&&value.name.length<=120&&['draft','enrolling','active','completed','archived'].includes(value.status)}
export async function fetchParticipantPrograms(cursor:number|null=null,signal?:AbortSignal):Promise<ParticipantPrograms>{
 if(cursor!==null&&!validId(cursor))throw new Error('Use a valid program page.')
 const result=await fetchPrivateJson<ParticipantPrograms>(`/api/v1/participant_programs${cursor===null?'':`?cursor=${cursor}`}`,{signal,cache:'no-store'})
 if(!validId(result.actor_id)||typeof result.selection_unavailable!=='boolean'||!Array.isArray(result.programs)||result.programs.length>50||!result.programs.every((row,index)=>program(row)&&row.id>(index?result.programs[index-1].id:cursor??0))||(result.next_cursor!==null&&(!validId(result.next_cursor)||result.next_cursor!==result.programs.at(-1)?.id))||(result.current_cohort_id!==null&&(!validId(result.current_cohort_id)||!program(result.current_program!)||result.current_program!.id!==result.current_cohort_id))||(result.current_cohort_id===null&&result.current_program!==null)||(result.selection_unavailable&&result.current_cohort_id!==null))throw new Error('Program choices could not be verified. Refresh before choosing.')
 return result
}
