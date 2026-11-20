import { cashCoverage } from '../lib/cashCoverage'
import { useEffect, useRef, useState } from 'react'
import type { CashPurchaseAnswer, CashPurchaseQuestion } from '../api'
import { formatHouseholdDay } from '../lib/householdDate'
import { formatReviewMoney } from '../lib/reviewMoney'

type Props = {
  questions: CashPurchaseQuestion[]
  /** Every purchase that needs an answer, as Home counts them. Review lists the newest few. */
  totalCount?: number
  disabled?: boolean
  errors?: Record<string, string>
  onAnswer: (question: CashPurchaseQuestion, answer: CashPurchaseAnswer) => Promise<void>
}

/**
 * Cash purchases she already confirmed that need her answer about the cash she took out: logged before the statement
 * with the withdrawal was approved, or the withdrawal it named was removed or made smaller. Each says what counts right
 * now. Nothing is linked for her: Yes names that cash (the purchase adds nothing), No keeps it counting on its own.
 */
export function CashPurchaseQuestions({ questions, totalCount = questions.length, disabled = false, errors = {}, onAnswer }: Props) {
  const [busy, setBusy] = useState<number | null>(null)
  const sectionRef = useRef<HTMLElement>(null)
  // After an answer saves, its question goes away; keyboard focus moves to the question that takes its place.
  const focusAfter = useRef<number | null>(null)
  useEffect(() => {
    const index = focusAfter.current
    if (index === null) return
    focusAfter.current = null
    const section = sectionRef.current
    const active = document.activeElement
    if (!section || (active && active !== document.body && !section.contains(active))) return
    const titles = section.querySelectorAll<HTMLElement>('.cash-purchase-question__title')
    ;(titles[Math.min(index, titles.length - 1)] ?? section.querySelector<HTMLElement>('h3'))?.focus()
  }, [questions])
  if (questions.length === 0) return null

  async function answer(question: CashPurchaseQuestion, choice: CashPurchaseAnswer) {
    setBusy(question.transaction_draft_id)
    // Set before saving: the list can drop this question before the save resolves.
    focusAfter.current = questions.findIndex(row => row.transaction_draft_id === question.transaction_draft_id)
    try {
      await onAnswer(question, choice)
    } catch {
      focusAfter.current = null
      // The error is shown beside this question.
    } finally {
      setBusy(null)
    }
  }

  return (
    <section ref={sectionRef} className="cash-purchase-questions" aria-labelledby="cash-purchase-questions-heading">
      <h3 id="cash-purchase-questions-heading" className="ui-section">Paid with cash</h3>
      <p className="cash-purchase-questions__intro">Cash counts when you take it out. Say which cash paid for {questions.length === 1 ? 'this purchase' : 'these purchases'} so it isn’t counted twice.</p>
      {totalCount > questions.length && <p className="cash-purchase-questions__intro">Showing the newest {questions.length} of {totalCount}. The rest appear as you answer these.</p>}
      <ul className="cash-purchase-questions__list">
        {questions.map((question) => {
          const saving = busy === question.transaction_draft_id
          const locked = disabled || busy !== null
          const name = `${question.merchant} on ${formatHouseholdDay(question.occurred_on)}`
          const error = errors[`cash:${question.transaction_draft_id}`]
          return (
            <li key={question.transaction_draft_id} className="cash-purchase-question transaction-cash-question" data-review-item={question.transaction_draft_id}>
              <p className="cash-purchase-question__title" tabIndex={-1}>
                <strong>{question.merchant}</strong>
                <span>{formatHouseholdDay(question.occurred_on)} · {formatReviewMoney(question.amount_cents)}</span>
              </p>
              <p className="transaction-cash-question__note">{question.message}</p>
              <div className="transaction-duplicate-question__row">
                {question.question && <p>{question.question}</p>}
                {question.question && <small>{cashCoverage(question.cash_cents, question.candidates)}</small>}
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
