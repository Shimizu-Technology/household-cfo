import { useState } from 'react'
import type { SavingsPlanDraft } from '../lib/savingsChallenge'
import { ComfortablePlanSummary } from './ComfortablePlanChoices'
export function SavingsPlanApprovalReview({draft,disabled,onApprove}:{draft:SavingsPlanDraft;disabled:boolean;onApprove:()=>void}) {
  const [reviewed,setReviewed]=useState(false)
  const additional = Boolean(draft.financial_baseline_version_id || draft.spending_changes?.length)
  return <div><p>This plan is a proposal. Your accepted target and choices stay unchanged until approval.</p><ComfortablePlanSummary plan={draft}/>{additional&&<label className="savings-check"><input type="checkbox" checked={reviewed} disabled={disabled} onChange={event=>setReviewed(event.target.checked)}/>I reviewed this saved target, comfortable choices, 90-day estimates and baseline limitations.</label>}<button type="button" disabled={disabled||additional&&!reviewed} onClick={onApprove}>Approve target plan #{draft.id}</button></div>
}
