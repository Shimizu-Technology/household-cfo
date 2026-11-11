import { useEffect, useRef, useState } from 'react'
import { formatMonthDay } from '../lib/plainDates'
import { sourceEventTitle, sourceMoney, type SourceEvent } from '../lib/sourceReview'
import {
  APPROVE_PAGE, LINE_KIND_OPTIONS, accountSentence, asBeforeNote, coverageMissingNote, lineKindFor, lineSheetFromAttention, readyCategoryLabel, statementHeadline,
  type AccountChange, type LineDecision, type LineEdit, type PlanAnswerId, type PlanAttention, type SheetLine,
} from '../lib/statementReview'
import { useStatementReview } from '../lib/useStatementReview'
import { Button } from './Button'
import { StatementAnswers } from './StatementAnswers'
import { StatementAccountSheet, StatementLineSheet } from './StatementSheets'
import './StatementSourceReview.css'

type Sheet = { kind: 'line'; line: SheetLine } | { kind: 'account' } | null

export function StatementSourceReview({ importId, revisionId, refreshKey, next, onSaved }: {
  importId: number; revisionId: number; refreshKey: string
  onSaved?: () => void
  /** Where she goes once every line is saved. The first is the main step (what Mia notices); the rest are quieter. */
  next?: Array<{ label: string; run: () => void }>
}) {
  const [page, setPage] = useState(1)
  const [sheet, setSheet] = useState<Sheet>(null)
  const [listOpen, setListOpen] = useState(false)
  const recoveryControls = useRef<HTMLDivElement>(null)
  const heading = useRef<HTMLHeadingElement>(null)
  const exceptions = useRef<HTMLUListElement>(null)
  const state = useStatementReview({ importId, revisionId, refreshKey, page, onSaved })
  const { data, error, review, plan, categories, names, needBasis, counts, mutation, busy, coverage, savingLines, unsavedAnswer, focusAfterRef, save } = state
  const pageData = data && data.pagination.page === page ? data : undefined

  // After an answer is saved the row disappears; keyboard focus moves to the next question, or back to the summary.
  useEffect(() => {
    if (!data || focusAfterRef.current === undefined) return
    const index = focusAfterRef.current
    focusAfterRef.current = undefined
    const next = index == null ? null : exceptions.current?.children[index]?.querySelector<HTMLElement>('select, button:not([disabled])')
    ;(next ?? heading.current)?.focus()
  }, [data, focusAfterRef])

  const pendingRequest = mutation.pendingRequest
  useEffect(() => {
    // Once a retained request's sheet closes, put keyboard users on its recovery controls.
    if (!sheet && pendingRequest && !pendingRequest.working) recoveryControls.current?.querySelector<HTMLButtonElement>('button')?.focus()
  }, [sheet, pendingRequest])

  const readyById = new Map((plan?.ready ?? []).map((line) => [line.event_id, line]))

  function answer(item: PlanAttention, index: number, id: PlanAnswerId, categoryId?: number) {
    if (id === 'edit' && categoryId == null) return setSheet({ kind: 'line', line: lineSheetFromAttention(item) })
    state.answer(item, index, id, categoryId)
  }
  async function saveSheet(entry: LineDecision) {
    if (sheet?.kind === 'line') entry.expected_head = sheet.line.expectedHead
    if (await save({ lines: [entry] })) setSheet(null)
  }
  async function saveAccounts(changes: AccountChange[]) {
    if (await save({ lines: [], accounts: changes })) setSheet(null)
  }

  const money = (cents: number | null) => (cents == null ? 'Unknown' : sourceMoney(Math.abs(cents)))
  function sheetFromEvent(event: SourceEvent): SheetLine {
    const row = review?.rows[event.id]
    const facts = row?.approved && row.approved.current !== false ? row.approved.facts : null
    // A line that is not saved yet opens on the kind and category the list shows for it (the plan's), not the reader's first guess.
    const planned = !facts ? plan?.attention.find((item) => item.event_id === event.id) : undefined
    if (planned) return lineSheetFromAttention(planned)
    const ready = !facts ? readyById.get(event.id) : undefined
    if (ready) {
      return { eventId: event.id, expectedHead: ready.expected_head, merchant: sourceEventTitle(event), postedOn: event.posted_on ?? '', amountCents: event.signed_amount_cents == null ? null : Math.abs(event.signed_amount_cents),
        kind: lineKindFor(ready.event_type, event.signed_amount_cents), categoryId: ready.category_id, leftOut: false }
    }
    const signed = facts ? facts.signed_amount_cents : event.signed_amount_cents
    return { eventId: event.id, expectedHead: row?.head ? { approved_version_id: row.head.approved_version_id, lock_version: row.head.lock_version, account_version_id: review?.accounts.find((account) => account.source_account_id === event.financial_source_account_id)?.head?.approved_version_id ?? null } : undefined, merchant: facts?.merchant ?? sourceEventTitle(event), postedOn: (facts ? facts.posted_on : event.posted_on) ?? '',
      amountCents: signed == null ? null : Math.abs(signed), kind: lineKindFor(facts?.event_type ?? event.event_type, signed),
      categoryId: facts ? facts.budget_category_id : event.transaction_draft?.category_id ?? null, leftOut: facts?.disposition === 'exclude' }
  }

  if (!mutation.accessDenied && !data && !error) return <section className="statement-source-review" aria-label="Statement review"><p role="status">Opening your statement…</p></section>
  return (
    <section className="statement-source-review" aria-label="Statement review">
      {mutation.pendingRequest && !mutation.pendingRequest.working && <div ref={recoveryControls} className="statement-notice" role="status">
        <p>We’re not sure your last change saved.</p>
        {mutation.pendingRequest.error && <p>{mutation.pendingRequest.error}</p>}
        <div className="statement-answers">
          {mutation.checkStatus && <Button variant="secondary" disabled={mutation.pendingRequest.working} onClick={() => { void mutation.checkStatus?.() }}>Check again</Button>}
          {mutation.retry && <Button disabled={mutation.pendingRequest.working} onClick={() => { void mutation.retry?.() }}>Try again</Button>}
        </div>
        <details><summary>Details for support</summary><p>Reference: {mutation.pendingRequest.key}</p></details>
      </div>}
      {mutation.error && !sheet && !mutation.pendingRequest && <div className="statement-notice" role="alert"><p>{mutation.error}</p><Button variant="secondary" disabled={busy} onClick={state.resetAndReload}>Refresh statement</Button></div>}
      {error && <div className="statement-notice" role="alert"><p>{error}</p><div className="statement-answers">
        <Button variant="secondary" onClick={state.reload}>Try again</Button>
        {page > 1 && <Button variant="secondary" onClick={() => setPage(1)}>Back to the first lines</Button>}
      </div></div>}
      {data && review && plan && counts && <>
        <header className="statement-summary">
          <div className="statement-summary-line">
            <h5 ref={heading} tabIndex={-1}>{statementHeadline(data.accounts, names, plan)}</h5>
            <Button variant="secondary" size="compact" disabled={busy} onClick={() => setSheet({ kind: 'account' })}>Change</Button>
          </div>
          <p role="status">{counts.sentence}</p>
          {savingLines >= APPROVE_PAGE && busy && <p className="statement-muted" role="status">Saving {savingLines} lines. This can take a minute.</p>}
          {asBeforeNote(plan) && <p className="statement-muted">{asBeforeNote(plan)}</p>}
          {coverage.ask && <div className="statement-question-row">
            <p className="statement-question" id="statement-coverage-question">{plan.coverage.question}</p>
            <div className="statement-answers" role="group" aria-labelledby="statement-coverage-question">
              <Button variant={coverage.said === 'nothing_missing' ? 'primary' : 'secondary'} aria-pressed={coverage.said === 'nothing_missing'} disabled={busy} onClick={() => coverage.answer('nothing_missing')}>Nothing’s missing</Button>
              <Button variant={coverage.said === 'something_missing' ? 'primary' : 'secondary'} aria-pressed={coverage.said === 'something_missing'} disabled={busy} onClick={() => coverage.answer('something_missing')}>Something’s missing</Button>
            </div>
            {coverage.failed && !mutation.pendingRequest && <div className="statement-notice" role="alert"><p>We couldn’t save your answer yet. Please try again.</p>
              <div className="statement-answers"><Button variant="secondary" disabled={busy} onClick={coverage.answerAgain}>Try again</Button></div></div>}
            {coverage.recorded === 'something_missing' && <p className="statement-muted" role="status">{coverageMissingNote()}</p>}
          </div>}
          {needBasis.length === 1 && <div className="statement-question-row">
            <p className="statement-question">Is {accountSentence(names[needBasis[0].id]) || 'this'} a bank account or a credit card?</p>
            <div className="statement-answers">
              <Button variant="secondary" aria-pressed={unsavedAnswer?.accountId === needBasis[0].id && unsavedAnswer.basis === 'asset'} disabled={busy} onClick={() => state.chooseBasis(needBasis[0].id, 'asset')}>Bank account</Button>
              <Button variant="secondary" aria-pressed={unsavedAnswer?.accountId === needBasis[0].id && unsavedAnswer.basis === 'liability'} disabled={busy} onClick={() => state.chooseBasis(needBasis[0].id, 'liability')}>Credit card</Button>
            </div>
          </div>}
          {needBasis.length > 1 && <Button disabled={busy} onClick={() => setSheet({ kind: 'account' })}>Say what each account is</Button>}
          {needBasis.length === 0 && counts.action && <>
            <ul className="statement-ready" aria-label="Lines to approve together">
              {plan.ready.slice(0, APPROVE_PAGE).map(line => <li key={line.event_id}>
                <span>{line.merchant || 'Statement line'}</span>
                <span>{line.signed_amount_cents == null ? '' : sourceMoney(line.signed_amount_cents, true)} · {line.informational ? 'Information only' : readyCategoryLabel(line) || LINE_KIND_OPTIONS.find(option => option.value === lineKindFor(line.event_type, line.signed_amount_cents ?? null))?.label}</span>
              </li>)}
            </ul>
            <Button disabled={busy} onClick={() => { void state.approveRest() }}>{mutation.pendingRequest?.working ? 'Saving' : counts.action}</Button>
          </>}
          {needBasis.length === 0 && counts.attention === 0 && counts.open === 0 && plan.total > 0 && (!coverage.ask || coverage.recorded) && next?.map((step, index) => <Button key={step.label} variant={index === 0 ? 'primary' : 'secondary'} onClick={step.run}>{step.label}</Button>)}
        </header>

        {plan.attention.length > 0 && <ul className="statement-exceptions" ref={exceptions} aria-label="Lines that need a quick look">
          {plan.attention.map((item, index) => <li key={item.event_id} className="statement-exception">
            <button type="button" className="statement-line" disabled={busy} aria-label={`Edit ${item.merchant ?? 'this line'}`} onClick={() => setSheet({ kind: 'line', line: lineSheetFromAttention(item) })}>
              <span className="statement-line-name">{item.merchant ?? 'Unreadable line'}</span>
              <span className="statement-line-amount">{money(item.signed_amount_cents)}</span>
              <span className="statement-line-meta">{[formatMonthDay(item.posted_on) || 'Date unknown', item.category_name].filter(Boolean).join(' · ')}</span>
            </button>
            <p className="statement-question" id={`statement-question-${item.event_id}`}>{item.question}</p>
            <StatementAnswers item={item} categories={categories} disabled={busy || needBasis.length > 0} unsaved={unsavedAnswer} onAnswer={(id, categoryId) => answer(item, index, id, categoryId)} />
          </li>)}
        </ul>}

        {unsavedAnswer && !mutation.pendingRequest && <Button variant="secondary" disabled={busy} onClick={state.retryUnsaved}>Try saving this answer again</Button>}

        <details className="statement-all" open={listOpen} onToggle={(event) => setListOpen(event.currentTarget.open)}>
          <summary>See all {plan.total.toLocaleString('en-US')} {plan.total === 1 ? 'line' : 'lines'}</summary>
          {!pageData && !error && <p role="status" className="statement-muted">Loading lines…</p>}
          {pageData && <table className="statement-table">
            <caption className="sr-only">Every line in this statement</caption>
            <thead><tr><th scope="col">Line</th><th scope="col" className="statement-date-cell">Date</th><th scope="col" className="statement-num">Amount</th><th scope="col">Category</th></tr></thead>
            <tbody>
              {pageData.events.map((event) => {
                const row = review.rows[event.id]
                const facts = row?.approved && row.approved.current !== false ? row.approved.facts : null
                const attention = plan.attention.some((item) => item.event_id === event.id)
                const signed = facts ? facts.signed_amount_cents : event.signed_amount_cents
                const kind = lineKindFor(facts?.event_type ?? event.event_type, signed)
                const ready = readyById.get(event.id)
                // A line that looks right shows the category the server will save for it, not only the reader's guess.
                const category = facts ? categories.find((entry) => entry.id === facts.budget_category_id)?.name : ready ? readyCategoryLabel(ready) ?? undefined : event.transaction_draft?.category_name
                const label = facts?.disposition === 'exclude' ? 'Left out' : attention ? 'Needs a look' : kind === 'spending' ? category ?? 'No category' : LINE_KIND_OPTIONS.find((option) => option.value === kind)?.label.replace('Moved between my accounts', 'Moved') ?? ''
                return <tr key={event.id} data-needs-look={attention || undefined}>
                  <td><button type="button" className="statement-link" disabled={busy} onClick={() => setSheet({ kind: 'line', line: sheetFromEvent(event) })}>{facts?.merchant ?? sourceEventTitle(event)}</button><span className="statement-date-inline" aria-hidden="true">{formatMonthDay(facts ? facts.posted_on : event.posted_on) || '—'}</span></td>
                  <td className="statement-date-cell">{formatMonthDay(facts ? facts.posted_on : event.posted_on) || '—'}</td>
                  <td className="statement-num">{signed == null ? 'Unknown' : sourceMoney(signed, true)}</td>
                  <td>{label}</td>
                </tr>
              })}
            </tbody>
          </table>}
          {data.pagination.total_pages > 1 && <nav className="statement-pager" aria-label="More lines">
            <Button variant="secondary" disabled={busy || page <= 1} onClick={() => setPage(page - 1)}>Earlier lines</Button>
            <span>Page {page} of {data.pagination.total_pages}</span>
            <Button variant="secondary" disabled={busy || page >= data.pagination.total_pages} onClick={() => setPage(page + 1)}>Later lines</Button>
          </nav>}
        </details>
      </>}

      {sheet?.kind === 'line' && <StatementLineSheet key={sheet.line.eventId} line={sheet.line} categories={categories} busy={busy} canClose={!mutation.pendingRequest?.working} error={mutation.error}
        onClose={() => setSheet(null)}
        onSave={(edit: LineEdit) => { void saveSheet({ event_id: sheet.line.eventId, decision: 'edited', edit }) }}
        onLeaveOut={() => { void saveSheet({ event_id: sheet.line.eventId, decision: 'leave_out' }) }} />}
      {sheet?.kind === 'account' && data && review && <StatementAccountSheet accounts={needBasis.length > 1 ? needBasis : data.accounts} reviewed={review.accounts} names={names} busy={busy} canClose={!mutation.pendingRequest?.working} error={mutation.error}
        onClose={() => setSheet(null)} onSave={(changes) => { void saveAccounts(changes) }} />}
    </section>
  )
}
