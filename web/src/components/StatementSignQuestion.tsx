import type { useStatementReview } from '../lib/useStatementReview'
import { Button } from './Button'

export function StatementSignQuestion({ state, disabled = false }: { disabled?: boolean; state: ReturnType<typeof useStatementReview> }) {
  if (state.needBasis.length > 0) return null
  if (!state.plan?.signed_amount_question && !state.plan?.signed_amount_answerable) return state.plan?.sign_effect ? <p role="status">{state.plan.sign_effect}</p> : null
  const liability = state.data?.accounts.some(account => (state.review?.accounts.find(reviewed => reviewed.source_account_id === account.id)?.approved?.tracked_account.account_basis ?? account.account_basis) === 'liability')
  return <div className="statement-question-row">
    {state.plan?.sign_effect && <p role="status">{state.plan.sign_effect}</p>}
    <p className="statement-question">{state.plan?.signed_amount_single_sign ? "Every amount in this file is shown the same way. Is it all money out, all money in, or a mix?" : <>In this {liability ? 'credit card' : 'bank account'} file, is money you spent shown as a negative amount (with a minus sign or parentheses)?</>}</p>
    <p>Your answer applies only to lines whose direction was unclear. You’ll still review the lines before approving them.</p>
    <div className="statement-answers">
      {state.plan?.signed_amount_single_sign ? <>
        <Button variant="secondary" disabled={disabled || state.busy || state.refreshing} onClick={() => { void state.answerSign('all_out') }}>All money out</Button>
        <Button variant="secondary" disabled={disabled || state.busy || state.refreshing} onClick={() => { void state.answerSign('all_in') }}>All money in</Button>
      </> : <><Button variant="secondary" disabled={disabled || state.busy || state.refreshing} onClick={() => { void state.answerSign(true) }}>Yes, spending is negative</Button>
      <Button variant="secondary" disabled={disabled || state.busy || state.refreshing} onClick={() => { void state.answerSign(false) }}>No, spending is positive</Button></>}
      <Button variant="secondary" disabled={disabled || state.busy || state.refreshing} onClick={() => { void state.answerSign('individual') }}>{state.plan?.signed_amount_single_sign ? 'A mix' : 'I’m not sure'}</Button>
    </div>
    {state.signError && <p role="alert">{state.signError}</p>}
  </div>
}
