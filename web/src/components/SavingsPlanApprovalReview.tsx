import { useEffect, useRef, useState } from 'react'
import type { SavingsPlanDraft } from '../lib/savingsChallenge'
import { ComfortablePlanSummary } from './ComfortablePlanChoices'
// autoFocus: after a target is prepared (or the form closes), move focus here so it doesn't fall to the page.
// It only takes focus when nothing else holds it, so a late load never pulls focus away from the participant.
export function SavingsPlanApprovalReview({draft,disabled,onApprove,autoFocus,onFocused}:{draft:SavingsPlanDraft;disabled:boolean;onApprove:()=>void;autoFocus?:boolean;onFocused?:()=>void}) {
  const [reviewed,setReviewed]=useState(false)
  const additional = Boolean(draft.financial_baseline_version_id || draft.spending_changes?.length)
  const checkbox=useRef<HTMLInputElement>(null), button=useRef<HTMLButtonElement>(null)
  useEffect(()=>{
    if(!autoFocus)return
    const active=document.activeElement
    const free=!active||active===document.body||(active instanceof HTMLElement&&active.tabIndex===-1&&/^H[1-6]$/.test(active.tagName))
    if(free){const destination=additional?checkbox.current:button.current;destination?.scrollIntoView?.({block:'center'});destination?.focus()}
    onFocused?.()
  // Runs once when this review appears.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  },[])
  return <div><p>Nothing changes until you confirm.</p><ComfortablePlanSummary plan={draft}/>{additional&&<label className="savings-check"><input ref={checkbox} data-plan-confirm type="checkbox" checked={reviewed} disabled={disabled} onChange={event=>setReviewed(event.target.checked)}/>I reviewed this saved target, my spending choices, the 90-day estimates and the spending snapshot’s limits.</label>}<button ref={button} data-plan-confirm={additional?undefined:true} type="button" disabled={disabled||additional&&!reviewed} onClick={onApprove} className="savings-action">Confirm target plan #{draft.id}</button></div>
}
