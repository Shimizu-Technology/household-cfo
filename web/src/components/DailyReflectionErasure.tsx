import { useState } from 'react'
import type { DailyMutate } from '../lib/useDailyMutation'
export type ErasableReflection = { id: number; current_version_id: number | null; lock_version: number; created_at?: string; erased_at?: string | null }
// Accepts metadata only, so the privacy screen can render this during a hold
// without receiving a purchase, financial record, or reflection text.
export function DailyReflectionErasure({ reflection, mutate, busy }: { reflection: ErasableReflection; mutate: DailyMutate; busy: boolean }) {
  const [accepted,setAccepted] = useState(false)
  const [complete,setComplete] = useState(false)
  async function erase() {
    const result = await mutate('reflection_erase',{erase_accepted:true,expected_version_id:reflection.current_version_id,expected_head_lock_version:reflection.lock_version},reflection.id)
    if(result){setComplete(true);setAccepted(false)}
  }
  return <fieldset disabled={busy||complete}><legend>Erase optional feelings</legend>{reflection.created_at&&<p>Reflection created {reflection.created_at}</p>}{complete||reflection.erased_at?<p role="status">Feelings erased. Financial history stays intact.</p>:<><label className="daily-check"><input type="checkbox" checked={accepted} onChange={event=>setAccepted(event.target.checked)}/><span>Erase my feelings from every version of this reflection. Financial history stays intact.</span></label><button type="button" disabled={!accepted} onClick={()=>void erase()}>Erase all versions of these feelings</button></>}</fieldset>
}
