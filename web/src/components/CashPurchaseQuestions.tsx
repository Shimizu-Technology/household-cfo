import { useState } from 'react'
import type { CashPurchaseAnswer, CashPurchaseQuestion } from '../api'
import { formatHouseholdDay } from '../lib/householdDate'
import { formatReviewMoney } from '../lib/reviewMoney'

type Props = {
  questions: CashPurchaseQuestion[]
  disabled?: boolean
  errors?: Record<string, string>
  onAnswer: (question: CashPurchaseQuestion, answer: CashPurchaseAnswer) => Promise<void>
}

/**
 * Cash purchases she already confirmed that need her answer about the cash she took out: logged before the statement
 * with the withdrawal was approved, or the withdrawal it named was removed or made smaller. Each says what counts right
 * now. Nothing is linked for her: Yes names that cash (the purchase adds nothing), No keeps it counting on its own.
 */
export function CashPurchaseQuestions({ questions, disabled = false, errors = {}, onAnswer }: Props) {
  const [busy, setBusy] = useState<number | null>(null)
  if (questions.length === 0) return null

  async function answer(question: CashPurchaseQuestion, choice: CashPurchaseAnswer) {
    setBusy(question.transaction_draft_id)
    try {
      await onAnswer(question, choice)
    } catch {
      // The error is shown beside this question.
    } finally {
      setBusy(null)
    }
  }

  return (
    <section className="cash-purchase-questions" aria-labelledby="cash-purchase-questions-heading">
      <h3 id="cash-purchase-questions-heading" className="ui-section">Paid with cash</h3>
      <p className="cash-purchase-questions__intro">Cash counts when you take it out. Say which cash paid for {questions.length === 1 ? 'this purchase' : 'these purchases'} so it isn’t counted twice.</p>
      <ul className="cash-purchase-questions__list">
        {questions.map((question) => {
          const saving = busy === question.transaction_draft_id
          const locked = disabled || busy !== null
          const name = `${question.merchant} on ${formatHouseholdDay(question.occurred_on)}`
          const error = errors[`cash:${question.transaction_draft_id}`]
          return (
            <li key={question.transaction_draft_id} className="cash-purchase-question transaction-cash-question" data-review-item={question.transaction_draft_id}>
              <p className="cash-purchase-question__title">
                <strong>{question.merchant}</strong>
                <span>{formatHouseholdDay(question.occurred_on)} · {formatReviewMoney(question.amount_cents)}</span>
              </p>
              <p className="transaction-cash-question__note">{question.message}</p>
              <div className="transaction-duplicate-question__row">
                {question.question && <p>{question.question}</p>}
                {question.question && <small>Your cash already counted when you took it out, so {question.candidates.length === 1 ? 'Yes doesn’t' : 'choosing it doesn’t'} add to your spending.</small>}
                <div className="transaction-duplicate-question__actions">
                  {question.candidates.map((candidate) => {
                    const text = question.candidates.length === 1 ? 'Yes' : `${candidate.label.charAt(0).toUpperCase()}${candidate.label.slice(1)}`
                    return (
                      <button key={candidate.financial_source_event_id} type="button" className="ui-btn ui-btn--primary" disabled={locked}
                        aria-label={`${saving ? 'Saving' : 'Yes'}: ${name} was paid with ${candidate.label}`}
                        onClick={() => void answer(question, { cashWithdrawalEventId: candidate.financial_source_event_id })}>
                        {saving ? 'Saving' : text}
                      </button>
                    )
                  })}
                  <button type="button" className={`ui-btn ${question.candidates.length ? 'ui-btn--tonal' : 'ui-btn--primary'}`} disabled={locked}
                    aria-label={`${saving ? 'Saving' : question.decline_label}: ${name}`}
                    onClick={() => void answer(question, { cashFromElsewhere: true })}>
                    {saving ? 'Saving' : question.decline_label}
                  </button>
                </div>
              </div>
              {error && <p className="setup-error" role="alert">{error}</p>}
            </li>
          )
        })}
      </ul>
    </section>
  )
}
