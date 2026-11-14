import type { MiaActionDraft } from '../api'

export function miaReviewResult(draft: MiaActionDraft) {
  if (draft.purchase_change && draft.status === 'applied') return 'Applied'
  return draft.status === 'applied'
    ? 'Applied to your approved household plan. Actual spending did not change.'
    : draft.draft_type === 'action_plan' && (draft.applied_item_count ?? 0) > 0
      ? `Canceled the remaining plan. ${draft.applied_item_count} previously applied ${draft.applied_item_count === 1 ? 'step remains' : 'steps remain'} in effect.`
      : 'Canceled. No household numbers changed.'
}
