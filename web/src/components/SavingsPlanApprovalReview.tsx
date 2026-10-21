import { useState } from 'react'
import type { SavingsPlanDraft } from '../lib/savingsChallenge'
import { ComfortablePlanSummary } from './ComfortablePlanChoices'
export function SavingsPlanApprovalReview({draft,disabled,onApprove}:{draft:SavingsPlanDraft;disabled:boolean;onApprove:()=>void}) {
  const [reviewed,setReviewed]=useState(false)
  const additional = Boolean(draft.financial_baseline_version_id || draft.spending_changes?.length)
  return <div><p>Nothing changes until you confirm.</p><ComfortablePlanSummary plan={draft}/>{additional&&<label className="savings-check"><input type="checkbox" checked={reviewed} disabled={disabled} onChange={event=>setReviewed(event.target.checked)}/>I reviewed this saved target, my spending choices, the 90-day estimates and the spending snapshot’s limits.</label>}<button type="button" disabled={disabled||additional&&!reviewed} onClick={onApprove} className="savings-action">Confirm target plan #{draft.id}</button></div>
}
