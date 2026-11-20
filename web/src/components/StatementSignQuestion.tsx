import { useLayoutEffect, useRef, useState } from 'react'
import type { AccountSignQuestion } from '../lib/statementReview'
import type { useStatementReview } from '../lib/useStatementReview'
import { Button } from './Button'

type ReviewState = ReturnType<typeof useStatementReview>

export function StatementSignQuestion({ state, disabled = false }: { disabled?: boolean; state: ReviewState }) {
  const [editingEffect, setEditingEffect] = useState<string | null>(null)
  const questionRef = useRef<HTMLParagraphElement>(null)
  const revealFocus = useRef(false)
  useLayoutEffect(() => {
    if (revealFocus.current) {
      revealFocus.current = false
      questionRef.current?.focus()
    }
  }, [editingEffect])
  const effect = state.plan?.sign_effect
  const canAnswer = state.plan?.signed_amount_question || state.plan?.signed_amount_answerable
  const showQuestion = !effect || editingEffect === effect
  if (state.needsAccount) return null
  if (state.plan?.account_sign_questions?.length) return <AccountSignQuestions state={state} disabled={disabled} questions={state.plan.account_sign_questions} />
  if (!canAnswer) return effect ? <p className="statement-sign-result" tabIndex={-1} role="status">{effect}</p> : null
  const liability = state.data?.accounts.some(account => (state.review?.accounts.find(reviewed => reviewed.source_account_id === account.id)?.approved?.tracked_account.account_basis ?? account.account_basis) === 'liability')
  return <div className="statement-question-row">
    {effect && <p className="statement-sign-result" tabIndex={-1} role="status">{effect}</p>}
    {!showQuestion && <Button variant="ghost" disabled={disabled || state.busy || state.refreshing} onClick={() => { revealFocus.current = true; setEditingEffect(effect!) }}>Change this</Button>}
    {showQuestion && <>
    <p ref={questionRef} tabIndex={-1} className="statement-question">{state.plan?.signed_amount_single_sign ? "Every amount in this file is shown the same way. Is it all money out, all money in, or a mix?" : <>In this {liability ? 'credit card' : 'bank account'} file, is money you spent shown as a negative amount (with a minus sign or parentheses)?</>}</p>
    <p>Your answer applies only to lines whose direction was unclear. You’ll still review the lines before approving them.</p>
    <SignAnswers singleSign={Boolean(state.plan?.signed_amount_single_sign)} disabled={disabled || state.busy || state.refreshing} answer={(choice) => { void state.answerSign(choice) }} />
    </>}
    {state.signError && <p role="alert">{state.signError}</p>}
  </div>
}

function SignAnswers({ singleSign, disabled, answer }: { singleSign: boolean; disabled: boolean; answer: (choice: boolean | 'all_out' | 'all_in' | 'individual') => void }) {
  return <div className="statement-answers">
    {singleSign ? <>
      <Button variant="secondary" disabled={disabled} onClick={() => answer('all_out')}>All money out</Button>
      <Button variant="secondary" disabled={disabled} onClick={() => answer('all_in')}>All money in</Button>
    </> : <><Button variant="secondary" disabled={disabled} onClick={() => answer(true)}>Yes, spending is negative</Button>
    <Button variant="secondary" disabled={disabled} onClick={() => answer(false)}>No, spending is positive</Button></>}
    <Button variant="secondary" disabled={disabled} onClick={() => answer('individual')}>{singleSign ? 'A mix' : 'I’m not sure'}</Button>
  </div>
}

/** One question per account, the next unanswered one first. Each answer sets only that account's unclear lines. */
function AccountSignQuestions({ state, disabled, questions }: { state: ReviewState; disabled: boolean; questions: AccountSignQuestion[] }) {
  const [changing, setChanging] = useState<number | null>(null)
  const questionRef = useRef<HTMLParagraphElement>(null)
  const revealFocus = useRef(false)
  useLayoutEffect(() => {
    if (revealFocus.current) {
      revealFocus.current = false
      questionRef.current?.focus()
    }
  }, [changing])
  const current = questions.find(question => question.answerable && question.source_account_id === changing) ?? questions.find(question => question.answerable && question.choice === null)
  const answered = questions.filter(question => question.choice !== null)
  const busy = disabled || state.busy || state.refreshing
  // While she answers, the account just before this one shows what her last answer did.
  const previous = current && answered.filter(question => questions.indexOf(question) < questions.indexOf(current) && question !== current).at(-1)
  const lines = answered.reduce((sum, question) => sum + question.lines, 0)
  return <div className="statement-question-row">
    {current ? <>
      {questions.length > 1 && <p>Account {questions.indexOf(current) + 1} of {questions.length}</p>}
      <p ref={questionRef} tabIndex={-1} className="statement-question" data-sign-next="">{current.single_sign
        ? <>Every amount in {current.label} is shown the same way. Is it all money out, all money in, or a mix?</>
        : <>In {current.label}, is money you spent shown as a negative amount (with a minus sign or parentheses)?</>}</p>
      <p>Your answer applies only to this account’s lines whose direction was unclear. You’ll still review the lines before approving them.</p>
      <SignAnswers singleSign={current.single_sign} disabled={busy} answer={(choice) => { void state.answerSign(choice, current.source_account_id).then(saved => { if (saved) setChanging(null) }) }} />
      {previous && <p className="statement-sign-result" tabIndex={-1} role="status">{previous.effect}</p>}
    </> : answered.length > 0 && <>
      <p className="statement-sign-result" tabIndex={-1} role="status">{answered.length === 1 ? answered[0].effect : `You answered money in or out for ${answered.length} accounts. That set the direction of ${lines} ${lines === 1 ? 'line' : 'lines'}.`}</p>
      <details className="statement-sign-accounts">
        <summary>{answered.some(question => question.answerable) ? 'See or change each account' : 'See each account'}</summary>
        {answered.map(question => <div key={question.source_account_id} className="statement-question-row">
          <p>{question.effect}</p>
          {question.answerable && <Button variant="ghost" disabled={busy} onClick={() => { revealFocus.current = true; setChanging(question.source_account_id) }}>{`Change ${question.label}`}</Button>}
        </div>)}
      </details>
    </>}
    {state.signError && <p role="alert">{state.signError}</p>}
  </div>
}
