import type { useStatementReview } from '../lib/useStatementReview'
import { Button } from './Button'

export function StatementSignQuestion({ state }: { state: ReturnType<typeof useStatementReview> }) {
  if (!state.plan?.signed_amount_question || state.needBasis.length > 0) return null
  const liability = state.review?.accounts.some(account => account.approved?.tracked_account.account_basis === 'liability') || state.data?.accounts.some(account => account.account_basis === 'liability')
  return <div className="statement-question-row">
    <p className="statement-question">In this {liability ? 'credit card' : 'bank account'} file, is money you spent shown as a negative amount (with a minus sign)?</p>
    <p>Your answer applies to every line. You’ll still review the lines before approving them.</p>
    <div className="statement-answers">
      <Button variant="secondary" disabled={state.busy || state.refreshing} onClick={() => { void state.answerSign(true) }}>Yes, spending is negative</Button>
      <Button variant="secondary" disabled={state.busy || state.refreshing} onClick={() => { void state.answerSign(false) }}>No, spending is positive</Button>
    </div>
    {state.signError && <p role="alert">{state.signError}</p>}
  </div>
}
