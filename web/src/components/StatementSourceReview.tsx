import { useEffect, useRef, useState } from 'react'
import { fetchDocumentSourceReview } from '../api'
import { formatMonthDay } from '../lib/plainDates'
import { sourceEventTitle, sourceMoney, validateSourceReview, type SourceEvent, type SourceReview } from '../lib/sourceReview'
import {
  APPROVE_PAGE, LINE_KIND_OPTIONS, accountNames, accountSentence, accountsNeedingBasis, asBeforeNote, coverageMissingNote, lineKindFor, readyCategoryLabel, statementCounts, statementHeadline,
  type AccountChange, type ApproveLinesInput, type CoverageAnswer, type LineDecision, type LineEdit, type PlanAnswerId, type PlanAttention,
} from '../lib/statementReview'
import { isStatementReviewActor } from '../lib/statementReviewRecovery'
import { useStatementReviewMutation } from '../lib/useStatementReviewMutation'
import { participantErrorMessage } from '../lib/participantErrorMessage'
import { Button } from './Button'
import { StatementAccountSheet, StatementLineSheet, type SheetLine } from './StatementSheets'
import './StatementSourceReview.css'

type Sheet = { kind: 'line'; line: SheetLine } | { kind: 'account' } | null

export function StatementSourceReview({ importId, revisionId, refreshKey, next }: {
  importId: number; revisionId: number; refreshKey: string
  /** Where she goes once every line is saved. The first is the main step (what Mia notices); the rest are quieter. */
  next?: Array<{ label: string; run: () => void }>
}) {
  const [page, setPage] = useState(1)
  const [attempt, setAttempt] = useState(0)
  const [sheet, setSheet] = useState<Sheet>(null)
  const [listOpen, setListOpen] = useState(false)
  const [savingLines, setSavingLines] = useState(0)
  // What she said about missing lines. It rides along with every save, and the server records it only when the statement is finished.
  const [coverageAnswer, setCoverageAnswer] = useState<CoverageAnswer | null>(null)
  // Her answer is kept on screen if saving it fails, with a plain way to try again; nothing moves on until it is recorded.
  const [coverageFailed, setCoverageFailed] = useState(false)
  const [result, setResult] = useState<{ key: string; data?: SourceReview; error?: string } | null>(null)
  const heading = useRef<HTMLHeadingElement>(null)
  const exceptions = useRef<HTMLUListElement>(null)
  const focusAfter = useRef<number | null | undefined>(undefined)
  const viewKey = `${importId}:${revisionId}:${page}`
  const requestKey = `${viewKey}:${attempt}:${refreshKey}`
  const mutation = useStatementReviewMutation({ importId, revisionId, scope: result?.data?.participant_review?.actor_scope, refresh: () => setAttempt((value) => value + 1) })
  const scoped = result?.data?.participant_review
  const actorReady = !scoped || Boolean(scoped.actor_scope && isStatementReviewActor(scoped.actor_scope))
  // The summary and the questions belong to the whole statement, so they stay on screen while another page of lines loads
  // or a saved answer is read back. This component is keyed by upload and revision, so nothing here can be another statement's.
  const data = !mutation.accessDenied && actorReady ? result?.data : undefined
  const pageData = data && data.pagination.page === page ? data : undefined
  const error = result?.key === requestKey ? result.error : undefined

  useEffect(() => {
    const controller = new AbortController()
    let live = true
    fetchDocumentSourceReview(importId, revisionId, page, 'all', controller.signal).then((payload) => {
      validateSourceReview(payload, importId, revisionId, page, 'all')
      const review = payload.participant_review
      if (!review?.plan || !review.actor_scope || !Number.isSafeInteger(review.actor_scope.user_id) || !Number.isSafeInteger(review.actor_scope.household_id)) throw new Error('This statement review isn’t available right now. Refresh to continue.')
      if (live) setResult({ key: requestKey, data: payload })
    }).catch((failure: unknown) => {
      if (live) setResult((previous) => ({ key: requestKey, data: previous?.data, error: participantErrorMessage(failure, 'Could not load this statement.') }))
    })
    return () => { live = false; controller.abort() }
  }, [importId, revisionId, page, requestKey, viewKey])

  // After an answer is saved the row disappears; keyboard focus moves to the next question, or back to the summary.
  useEffect(() => {
    if (!data || focusAfter.current === undefined) return
    const index = focusAfter.current
    focusAfter.current = undefined
    const next = index == null ? null : exceptions.current?.children[index]?.querySelector<HTMLElement>('select, button:not([disabled])')
    ;(next ?? heading.current)?.focus()
  }, [data])

  const review = data?.participant_review
  const plan = review?.plan
  const busy = mutation.busy
  const categories = review?.categories ?? []
  const names = data && review ? accountNames(data.accounts, review.accounts) : {}
  const needBasis = data && review ? accountsNeedingBasis(data.accounts, review.accounts) : []
  const counts = plan ? statementCounts(plan) : null
  const said = coverageAnswer ?? plan?.coverage.answer ?? null
  // Only what the server recorded counts as answered: the next step opens after the save that records it.
  const recorded = plan?.coverage.answer ?? null
  const askCoverage = Boolean(plan?.coverage.question) && plan?.total !== 0
  const readyById = new Map((plan?.ready ?? []).map((line) => [line.event_id, line]))

  async function save(input: ApproveLinesInput, focusIndex: number | null = null): Promise<boolean> {
    focusAfter.current = focusIndex
    const saved = await mutation.mutate('approve_lines', coverageAnswer && !input.coverage_answer ? { ...input, coverage_answer: coverageAnswer } : input)
    if (!saved) focusAfter.current = undefined
    return saved
  }
  function approveRest() {
    if (!plan) return
    // A long statement goes a page at a time: the lines of this page are exactly what the request saves.
    // Each line goes with the kind and category she was shown for it; the server saves nothing if any of them has changed.
    const page = plan.ready.slice(0, APPROVE_PAGE)
    setSavingLines(page.length)
    void save({
      expect_ready_ids: page.map((line) => line.event_id), ...(plan.ready.length > APPROVE_PAGE ? { paged: true } : {}),
      lines: page.map((line): LineDecision => ({ event_id: line.event_id, decision: 'as_read', shown: { event_type: line.event_type, category_id: line.category_id } })),
    }).finally(() => setSavingLines(0))
  }
  // The question is hers to answer. If every line is already saved the answer is saved now; otherwise it goes with the next save.
  function answerCoverage(value: CoverageAnswer) {
    setCoverageAnswer(value)
    setCoverageFailed(false)
    if (counts && counts.open === 0 && counts.attention === 0 && plan && plan.total > 0) void save({ lines: [], coverage_answer: value }).then((saved) => setCoverageFailed(!saved))
  }
  function chooseBasis(account: number, basis: 'asset' | 'liability') {
    void save({ lines: [], accounts: [{ source_account_id: account, account_basis: basis }] })
  }
  function answer(item: PlanAttention, index: number, id: PlanAnswerId, categoryId?: number) {
    if (id === 'edit' && categoryId == null) return setSheet({ kind: 'line', line: sheetFromAttention(item) })
    // "Yes" to "Still Dining out?" confirms that category and nothing else: the line keeps what kind of line it is.
    const entry: LineDecision = id === 'keep'
      ? { event_id: item.event_id, decision: 'as_read', shown: { event_type: item.event_type, category_id: item.category_id } }
      : id === 'edit'
        ? { event_id: item.event_id, decision: 'edited', edit: { ...sheetEdit(sheetFromAttention(item)), category_id: categoryId ?? item.category_id } }
        : id === 'leave_out'
          ? { event_id: item.event_id, decision: id }
          // Every answer that saves the line as the statement reads it says what she was shown, so the server can check it.
          : { event_id: item.event_id, decision: id, shown: { event_type: item.event_type, category_id: item.category_id } }
    void save({ lines: [entry] }, index)
  }
  async function saveSheet(entry: LineDecision) {
    if (await save({ lines: [entry] })) setSheet(null)
  }
  async function saveAccounts(changes: AccountChange[]) {
    if (await save({ lines: [], accounts: changes })) setSheet(null)
  }

  const money = (cents: number | null) => (cents == null ? 'Unknown' : sourceMoney(Math.abs(cents)))
  function sheetFromAttention(item: PlanAttention): SheetLine {
    return { eventId: item.event_id, merchant: item.merchant ?? '', postedOn: item.posted_on ?? '', amountCents: item.signed_amount_cents == null ? null : Math.abs(item.signed_amount_cents),
      kind: lineKindFor(item.event_type, item.signed_amount_cents), categoryId: item.category_id, leftOut: false }
  }
  function sheetFromEvent(event: SourceEvent): SheetLine {
    const row = review?.rows[event.id]
    const facts = row?.approved && row.approved.current !== false ? row.approved.facts : null
    // A line that is not saved yet opens on the kind and category the list shows for it (the plan's), not the reader's first guess.
    const planned = !facts ? plan?.attention.find((item) => item.event_id === event.id) : undefined
    if (planned) return sheetFromAttention(planned)
    const ready = !facts ? readyById.get(event.id) : undefined
    if (ready) {
      return { eventId: event.id, merchant: sourceEventTitle(event), postedOn: event.posted_on ?? '', amountCents: event.signed_amount_cents == null ? null : Math.abs(event.signed_amount_cents),
        kind: lineKindFor(ready.event_type, event.signed_amount_cents), categoryId: ready.category_id, leftOut: false }
    }
    const signed = facts ? facts.signed_amount_cents : event.signed_amount_cents
    return { eventId: event.id, merchant: facts?.merchant ?? sourceEventTitle(event), postedOn: (facts ? facts.posted_on : event.posted_on) ?? '',
      amountCents: signed == null ? null : Math.abs(signed), kind: lineKindFor(facts?.event_type ?? event.event_type, signed),
      categoryId: facts ? facts.budget_category_id : event.transaction_draft?.category_id ?? null, leftOut: facts?.disposition === 'exclude' }
  }

  if (!mutation.accessDenied && !data && !error) return <section className="statement-source-review" aria-label="Statement review"><p role="status">Opening your statement…</p></section>
  return (
    <section className="statement-source-review" aria-label="Statement review">
      {mutation.pendingRequest && !mutation.pendingRequest.working && <div className="statement-notice" role="status">
        <p>We’re not sure your last change saved.</p>
        <div className="statement-answers">
          {mutation.checkStatus && <Button variant="secondary" disabled={mutation.pendingRequest.working} onClick={() => { void mutation.checkStatus?.() }}>Check again</Button>}
          {mutation.retry && <Button disabled={mutation.pendingRequest.working} onClick={() => { void mutation.retry?.() }}>Try again</Button>}
        </div>
        <details><summary>Details for support</summary><p>Reference: {mutation.pendingRequest.key}</p></details>
      </div>}
      {mutation.error && !sheet && !mutation.pendingRequest && <p className="statement-notice" role="alert">{mutation.error}</p>}
      {error && <div className="statement-notice" role="alert"><p>{error}</p><div className="statement-answers">
        <Button variant="secondary" onClick={() => setAttempt((value) => value + 1)}>Try again</Button>
        {page > 1 && <Button variant="secondary" onClick={() => setPage(1)}>Back to the first lines</Button>}
      </div></div>}
      {data && review && plan && counts && <>
        <header className="statement-summary">
          <div className="statement-summary-line">
            <h5 ref={heading} tabIndex={-1}>{statementHeadline(data.accounts, names, plan)}</h5>
            <Button variant="secondary" size="compact" disabled={busy} onClick={() => setSheet({ kind: 'account' })}>Change</Button>
          </div>
          <p role="status">{counts.sentence}</p>
          {savingLines >= 100 && busy && <p className="statement-muted" role="status">Saving {savingLines} lines. This can take a minute.</p>}
          {asBeforeNote(plan) && <p className="statement-muted">{asBeforeNote(plan)}</p>}
          {askCoverage && <div className="statement-question-row">
            <p className="statement-question" id="statement-coverage-question">{plan.coverage.question}</p>
            <div className="statement-answers" role="group" aria-labelledby="statement-coverage-question">
              <Button variant={said === 'nothing_missing' ? 'primary' : 'secondary'} aria-pressed={said === 'nothing_missing'} disabled={busy} onClick={() => answerCoverage('nothing_missing')}>Nothing’s missing</Button>
              <Button variant={said === 'something_missing' ? 'primary' : 'secondary'} aria-pressed={said === 'something_missing'} disabled={busy} onClick={() => answerCoverage('something_missing')}>Something’s missing</Button>
            </div>
            {coverageFailed && !mutation.pendingRequest && <div className="statement-notice" role="alert"><p>We couldn’t save your answer yet. Please try again.</p>
              <div className="statement-answers"><Button variant="secondary" disabled={busy} onClick={() => { if (coverageAnswer) answerCoverage(coverageAnswer) }}>Try again</Button></div></div>}
            {recorded === 'something_missing' && <p className="statement-muted" role="status">{coverageMissingNote()}</p>}
          </div>}
          {needBasis.length === 1 && <div className="statement-question-row">
            <p className="statement-question">Is {accountSentence(names[needBasis[0].id]) || 'this'} a bank account or a credit card?</p>
            <div className="statement-answers">
              <Button variant="secondary" disabled={busy} onClick={() => chooseBasis(needBasis[0].id, 'asset')}>Bank account</Button>
              <Button variant="secondary" disabled={busy} onClick={() => chooseBasis(needBasis[0].id, 'liability')}>Credit card</Button>
            </div>
          </div>}
          {needBasis.length > 1 && <Button disabled={busy} onClick={() => setSheet({ kind: 'account' })}>Say what each account is</Button>}
          {needBasis.length === 0 && counts.action && <Button disabled={busy} onClick={approveRest}>{mutation.pendingRequest?.working ? 'Saving' : counts.action}</Button>}
          {needBasis.length === 0 && counts.attention === 0 && counts.open === 0 && plan.total > 0 && (!askCoverage || recorded) && next?.map((step, index) => <Button key={step.label} variant={index === 0 ? 'primary' : 'secondary'} onClick={step.run}>{step.label}</Button>)}
        </header>

        {plan.attention.length > 0 && <ul className="statement-exceptions" ref={exceptions} aria-label="Lines that need a quick look">
          {plan.attention.map((item, index) => <li key={item.event_id} className="statement-exception">
            <button type="button" className="statement-line" disabled={busy} aria-label={`Edit ${item.merchant ?? 'this line'}`} onClick={() => setSheet({ kind: 'line', line: sheetFromAttention(item) })}>
              <span className="statement-line-name">{item.merchant ?? 'Unreadable line'}</span>
              <span className="statement-line-amount">{money(item.signed_amount_cents)}</span>
              <span className="statement-line-meta">{[formatMonthDay(item.posted_on) || 'Date unknown', item.category_name].filter(Boolean).join(' · ')}</span>
            </button>
            <p className="statement-question" id={`statement-question-${item.event_id}`}>{item.question}</p>
            <div className="statement-answers" role="group" aria-labelledby={`statement-question-${item.event_id}`}>
              {item.answers.map((choice) => item.kind === 'no_category' && choice.id === 'edit'
                ? <select key={choice.id} aria-label={`Category for ${item.merchant ?? 'this line'}`} value="" disabled={busy || needBasis.length > 0} onChange={(event) => { if (event.target.value) answer(item, index, 'edit', Number(event.target.value)) }}>
                  <option value="">{choice.label}</option>
                  {categories.map((category) => <option key={category.id} value={category.id}>{category.name}</option>)}
                </select>
                : <Button key={choice.id} variant="secondary" disabled={busy || needBasis.length > 0} aria-label={`${choice.label}: ${item.merchant ?? 'this line'}`} onClick={() => answer(item, index, choice.id)}>{choice.label}</Button>)}
            </div>
          </li>)}
        </ul>}

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

      {sheet?.kind === 'line' && <StatementLineSheet key={sheet.line.eventId} line={sheet.line} categories={categories} busy={busy} error={mutation.error}
        onClose={() => setSheet(null)}
        onSave={(edit: LineEdit) => { void saveSheet({ event_id: sheet.line.eventId, decision: 'edited', edit }) }}
        onLeaveOut={() => { void saveSheet({ event_id: sheet.line.eventId, decision: 'leave_out' }) }} />}
      {sheet?.kind === 'account' && data && review && <StatementAccountSheet accounts={needBasis.length > 1 ? needBasis : data.accounts} reviewed={review.accounts} names={names} busy={busy} error={mutation.error}
        onClose={() => setSheet(null)} onSave={(changes) => { void saveAccounts(changes) }} />}
    </section>
  )
}

function sheetEdit(line: SheetLine): LineEdit {
  return { kind: line.kind, merchant: line.merchant, posted_on: line.postedOn, amount_cents: line.amountCents ?? 0, category_id: line.categoryId }
}
