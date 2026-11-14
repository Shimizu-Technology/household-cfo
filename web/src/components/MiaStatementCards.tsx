import { useLiveMiaResult } from '../lib/useLiveMiaResult'
import { useEffect, useMemo, useRef, useState } from 'react'
import type { FinancialDocumentImport } from '../api'
import { formatReviewMoney } from '../lib/reviewMoney'
import { MAX_STATEMENT_CARDS, monthsCovered, statementCardEntries, waitsOnMissingLines } from '../lib/statementCards'
import {
  APPROVE_PAGE, asBeforeNote, coverageMissingNote, describeAccounts, accountSentence, lineSheetFromAttention, statementPeriodText,
  type LineDecision, type LineEdit, type PlanAnswerId, type PlanAttention, type SheetLine, type StatementPlan,
} from '../lib/statementReview'
import { formatMonthDay } from '../lib/plainDates'
import { sourceMoney } from '../lib/sourceReview'
import { useStatementReview } from '../lib/useStatementReview'
import { Button } from './Button'
import { StatementAnswers } from './StatementAnswers'
import { StatementLineSheet } from './StatementSheets'
import './StatementSourceReview.css'
import './MiaStatementCards.css'

/** How many lines she answers right in the chat; the rest wait on the Statements screen. */
const INLINE_QUESTIONS = 3

type Props = {
  imports: FinancialDocumentImport[]
  assistantName: string
  /** Challenge participants are offered patterns in words; households get the existing "See what Mia notices" step. */
  challenge: boolean
  onReview: (documentImportId: number) => void
  /** Resolves false when the file could not be sent for reading again. */
  onRetry: (documentImport: FinancialDocumentImport) => Promise<boolean> | void
  /** True while Mia is answering: approving now could race her reply's numbers, so the card waits. */
  disabled?: boolean
  /** A statement was just saved: refresh the uploads and the numbers that read from them. */
  onSaved: () => void
  onAskPatterns?: () => void
}

/** One compact card per statement Mia has read, then one line to move on once they are all approved. */
export function MiaStatementCards({ imports, assistantName, challenge, onReview, onRetry, onSaved, onAskPatterns, disabled = false }: Props) {
  const [now] = useState(() => Date.now())
  const [askedNow, setAskedNow] = useState(false)
  // Statements from one account share what is known about it, so a save on one card changes what the others must show.
  const [saves, setSaves] = useState(0)
  const entries = useMemo(() => statementCardEntries(imports, now), [imports, now])
  const shown = entries.slice(-MAX_STATEMENT_CARDS)
  if (shown.length === 0) return null
  // Once she has asked, the offer is not made again for these statements in this browser session.
  const askedKey = `statement-patterns-asked:${shown.map((entry) => entry.documentImport.id).join(',')}`
  const asked = askedNow || readFlag(askedKey)
  const allApproved = shown.every((entry) => entry.stage === 'approved')
  // Every line is approved but she said something is missing: the offer waits, and she is told when it will come.
  const waitingOnMissing = !allApproved && shown.some(waitsOnMissingLines) && shown.every((entry) => entry.stage === 'approved' || waitsOnMissingLines(entry))
  const months = monthsCovered(shown.map((entry) => entry.documentImport))
  const scope = months >= 2 ? `your last ${months} months` : shown.length > 1 ? `these ${shown.length} statements` : 'this statement'
  return <div className="mia-statement-cards">
    {entries.length > shown.length && <p className="mia-statement-more">Your {entries.length - shown.length} older {entries.length - shown.length === 1 ? 'statement is' : 'statements are'} on the Statements screen.</p>}
    {shown.map(({ documentImport, stage }) => stage === 'reading' || stage === 'failed'
      ? <StatementProgressCard key={documentImport.id} documentImport={documentImport} failed={stage === 'failed'} onRetry={onRetry} onReview={onReview} />
      : <MiaStatementCard key={`${documentImport.id}:${documentImport.metadata.source_accounting_revision_id}`} documentImport={documentImport} onReview={onReview} saves={saves} waiting={disabled} onSaved={() => { setSaves((value) => value + 1); onSaved() }} />)}
    {waitingOnMissing && !asked && onAskPatterns && <p className="mia-statement-muted" role="status">I’ll offer to look for patterns once the missing lines are in.</p>}
    {allApproved && !asked && onAskPatterns && <section className="mia-statement-next ui-card" aria-label={`Next step with ${assistantName}`}>
      <p>{shown.length > 1 ? `All ${shown.length} statements are approved. ` : ''}Want me to look for patterns in {scope}?</p>
      <Button onClick={() => { writeFlag(askedKey); setAskedNow(true); onAskPatterns() }}>{challenge ? 'Yes, look for patterns' : `See what ${assistantName} notices`}</Button>
    </section>}
  </div>
}

function readFlag(key: string): boolean {
  try { return sessionStorage.getItem(key) === '1' } catch { return false }
}
function writeFlag(key: string) {
  try { sessionStorage.setItem(key, '1') } catch { /* the offer simply shows again */ }
}

// Still being read, or it could not be read. Nothing here can be approved.
function StatementProgressCard({ documentImport, failed, onRetry, onReview }: { documentImport: FinancialDocumentImport; failed: boolean; onRetry: Props['onRetry']; onReview: Props['onReview'] }) {
  const [retryFailed, setRetryFailed] = useState(false)
  const [retrying, setRetrying] = useState(false)
  const progress = documentImport.metadata.extraction_progress
  const pagesKnown = Number.isInteger(progress?.page) && Number.isInteger(progress?.page_count) && progress!.page! > 0 && progress!.page! <= progress!.page_count!
  if (!failed) {
    return <section className="mia-statement-card ui-card" data-import-id={documentImport.id} aria-label={`Reading ${documentImport.filename}`} aria-busy="true">
      <h3>{documentImport.filename}</h3>
      <p role="status">{pagesKnown ? `Reading page ${progress!.page} of ${progress!.page_count}…` : 'Reading your statement…'}</p>
      <p className="mia-statement-muted">You can leave this page. Your file is saved, and nothing counts until you approve it.</p>
    </section>
  }
  return <section className="mia-statement-card ui-card" data-import-id={documentImport.id} aria-label={`Could not read ${documentImport.filename}`}>
    <h3>{documentImport.filename}</h3>
    <p role="alert">{documentImport.extraction_error || 'I couldn’t read reliable lines from this file.'}</p>
    <p className="mia-statement-muted">{documentImport.source_available ? 'Nothing was saved. You can try reading it again, or upload a clearer copy.' : 'The original file has been removed, so please upload it again. Nothing was saved.'}</p>
    {retryFailed && <p role="alert">I couldn’t start reading it again just now. Try again in a moment, or open it in Statements.</p>}
    <div className="mia-statement-actions ui-actions">
      {documentImport.source_available && <Button disabled={retrying} onClick={async () => { setRetryFailed(false); setRetrying(true); try { if (await onRetry(documentImport) === false) setRetryFailed(true) } finally { setRetrying(false) } }}>Try reading it again</Button>}
      <Button variant="secondary" onClick={() => onReview(documentImport.id)}>Open in Statements</Button>
    </div>
  </section>
}

function MiaStatementCard({ documentImport, saves, waiting, onReview, onSaved }: { documentImport: FinancialDocumentImport; saves: number; waiting: boolean; onReview: Props['onReview']; onSaved: () => void }) {
  const importId = documentImport.id
  // Each saved answer moves her spending, so the uploads and numbers refresh as she goes; a card that opens already approved changes nothing.
  const state = useStatementReview({
    importId, revisionId: documentImport.metadata.source_accounting_revision_id!, onChanged: onSaved,
    refreshKey: `${documentImport.updated_at}:${JSON.stringify(documentImport.statement_review ?? null)}:${saves}`,
  })
  const liveResult = useLiveMiaResult(state.finished, Boolean(state.data))
  const { data, error, review, plan, categories, names, needBasis, counts, mutation, coverage, savingLines, unsavedAnswer } = state
  // Nothing is answered from lines that are being read again; the buttons come back as soon as the new read arrives.
  const busy = state.busy || state.refreshing || waiting
  const [sheet, setSheet] = useState<SheetLine | null>(null)
  const [note, setNote] = useState<string | null>(null)
  const heading = useRef<HTMLHeadingElement>(null)
  const questions = useRef<HTMLUListElement>(null)
  const { focusAfterRef } = state
  const pending = mutation.pendingRequest?.importId === importId ? mutation.pendingRequest : null

  // After an answer is saved her question is gone; focus moves to the next question, or back to the card's heading.
  useEffect(() => {
    if (!data || focusAfterRef.current === undefined) return
    const index = focusAfterRef.current
    focusAfterRef.current = undefined
    const next = index == null ? null : questions.current?.children[index]?.querySelector<HTMLElement>('select, button:not([disabled])')
    ;(next ?? heading.current)?.focus()
  }, [data, focusAfterRef])

  if (!data || !review || !plan || !counts) {
    if (error) return <section className="mia-statement-card ui-card" data-import-id={documentImport.id} aria-label="Statement"><h3>{documentImport.filename}</h3><p role="alert">{error}</p><Button variant="secondary" onClick={state.reload}>Try again</Button></section>
    return <section className="mia-statement-card ui-card" data-import-id={documentImport.id} aria-label="Statement" aria-busy="true"><h3>{documentImport.filename}</h3><p role="status">Opening your statement…</p></section>
  }

  const title = statementTitle(data.accounts, names, plan)
  const approved = state.finished
  const empty = plan.total === 0

  async function approve() {
    setNote(null)
    if (await state.approveRest()) return
    // The server refuses the whole request when the lines changed; show what is true now instead of leaving a stale count.
    if (mutation.lastFailure.current?.status === 409) {
      setNote('This statement changed, so nothing was approved. This is the latest.')
      state.reload()
    }
  }
  async function saveSheet(entry: LineDecision) {
    if (sheet) entry.expected_head = sheet.expectedHead
    if (await state.save({ lines: [entry] })) setSheet(null)
  }
  function answer(item: PlanAttention, index: number, id: PlanAnswerId, categoryId?: number) {
    if (id === 'edit' && categoryId == null) return setSheet(lineSheetFromAttention(item))
    state.answer(item, index, id, categoryId)
  }

  if (empty) {
    return <section className="mia-statement-card ui-card" data-import-id={importId} aria-label={`Statement: ${title}`}>
      <h3>{title}</h3>
      <p>I couldn’t find any lines in this statement. Nothing was saved.</p>
      <Button variant="secondary" onClick={() => onReview(importId)}>Open in Statements</Button>
    </section>
  }

  if (approved) {
    return <section className={`mia-statement-card is-approved ui-card${liveResult}`} data-import-id={importId} aria-label={`Statement: ${title}`}>
      <details className="ui-disclosure mia-statement-result">
        <summary><h3>{title}</h3> <strong>Approved.</strong></summary>
        <p role="status">{countedSentence(plan)}</p>
        {coverage.recorded === 'something_missing' && <p className="mia-statement-muted">{coverageMissingNote()}</p>}
      </details>
    </section>
  }

  const inline = plan.attention.slice(0, INLINE_QUESTIONS)
  const more = plan.attention.length - inline.length
  return <section className="mia-statement-card ui-card" data-import-id={importId} aria-label={`Statement: ${title}`} aria-busy={busy}>
    {pending && !pending.working && <div className="mia-statement-notice" role="status">
      <p>I’m not sure your last change saved.</p>
      {pending.error && <p>{pending.error}</p>}
      <div className="mia-statement-actions ui-actions">
        {mutation.checkStatus && <Button variant="secondary" onClick={() => { void mutation.checkStatus?.() }}>Check again</Button>}
        {mutation.retry && <Button onClick={() => { void mutation.retry?.() }}>Try again</Button>}
      </div>
    </div>}
    {mutation.error && !pending && !mutation.pendingRequest && <div className="mia-statement-notice" role="alert">
      <p>{mutation.error}</p>
      <Button variant="secondary" disabled={busy} onClick={state.resetAndReload}>Show the latest</Button>
    </div>}
    {note && <p className="mia-statement-notice" role="status">{note}</p>}
    <h3 ref={heading} tabIndex={-1}>{title}</h3>
    <p className="mia-statement-read">{readSentence(plan)}</p>
    <p role="status">{counts.sentence}</p>
    {savingLines >= APPROVE_PAGE && busy && <p className="mia-statement-muted" role="status">Saving {savingLines} lines. This can take a minute.</p>}
    {asBeforeNote(plan) && <p className="mia-statement-muted">{asBeforeNote(plan)}</p>}

    {needBasis.length === 1 && <div className="mia-statement-question">
      <p className="statement-question">Is {accountSentence(names[needBasis[0].id]) || 'this'} a bank account or a credit card?</p>
      <div className="statement-answers">
        <Button variant="secondary" disabled={busy} onClick={() => state.chooseBasis(needBasis[0].id, 'asset')}>Bank account</Button>
        <Button variant="secondary" disabled={busy} onClick={() => state.chooseBasis(needBasis[0].id, 'liability')}>Credit card</Button>
      </div>
    </div>}
    {needBasis.length > 1 && <Button disabled={busy} onClick={() => onReview(importId)}>Say what each account is</Button>}

    {needBasis.length === 0 && inline.length > 0 && <ul className="mia-statement-exceptions" ref={questions} aria-label="Lines that need a quick look">
      {inline.map((item, index) => <li key={item.event_id}>
        <p className="mia-statement-line"><span className="mia-statement-merchant">{item.merchant ?? 'Unreadable line'}</span> <span className="mia-statement-amount">{item.signed_amount_cents == null ? 'Unknown' : sourceMoney(Math.abs(item.signed_amount_cents))}</span>
          <span className="mia-statement-meta">{[formatMonthDay(item.posted_on) || 'Date unknown', item.category_name].filter(Boolean).join(' · ')}</span></p>
        <p className="statement-question" id={`statement-question-${item.event_id}`}>{item.question}</p>
        <StatementAnswers item={item} categories={categories} disabled={busy} unsaved={unsavedAnswer} inlineCategory onAnswer={(id, categoryId) => answer(item, index, id, categoryId)} />
      </li>)}
    </ul>}
    {needBasis.length === 0 && more > 0 && <Button variant="secondary" onClick={() => onReview(importId)}>{`and ${more} more — review ${more === 1 ? 'it' : 'them'}`}</Button>}
    {unsavedAnswer && !mutation.pendingRequest && <Button variant="secondary" disabled={busy} onClick={state.retryUnsaved}>Try saving this answer again</Button>}

    {needBasis.length === 0 && coverage.ask && <div className="mia-statement-question">
      <p className="statement-question" id={`statement-coverage-${importId}`}>{plan.coverage.question}</p>
      <div className="statement-answers" role="group" aria-labelledby={`statement-coverage-${importId}`}>
        <Button variant={coverage.said === 'nothing_missing' ? 'primary' : 'secondary'} aria-pressed={coverage.said === 'nothing_missing'} disabled={busy} onClick={() => coverage.answer('nothing_missing')}>Nothing’s missing</Button>
        <Button variant={coverage.said === 'something_missing' ? 'primary' : 'secondary'} aria-pressed={coverage.said === 'something_missing'} disabled={busy} onClick={() => coverage.answer('something_missing')}>Something’s missing</Button>
      </div>
      {coverage.failed && !mutation.pendingRequest && <div className="mia-statement-notice" role="alert"><p>I couldn’t save your answer yet. Please try again.</p><Button variant="secondary" disabled={busy} onClick={coverage.answerAgain}>Try again</Button></div>}
      {coverage.recorded === 'something_missing' && <p className="mia-statement-muted" role="status">{coverageMissingNote()}</p>}
    </div>}

    <div className="mia-statement-actions ui-actions">
      {needBasis.length === 0 && counts.action && <Button disabled={busy} onClick={() => { void approve() }}>{mutation.pendingRequest?.working ? 'Saving' : counts.action}</Button>}
      <Button variant="secondary" onClick={() => onReview(importId)}>See every line</Button>
    </div>

    {sheet && <StatementLineSheet key={sheet.eventId} line={sheet} categories={categories} busy={busy} canClose={!mutation.pendingRequest?.working} error={mutation.error}
      onClose={() => setSheet(null)}
      onSave={(edit: LineEdit) => { void saveSheet({ event_id: sheet.eventId, decision: 'edited', edit }) }}
      onLeaveOut={() => { void saveSheet({ event_id: sheet.eventId, decision: 'leave_out' }) }} />}
  </section>
}

function statementTitle(accounts: Parameters<typeof describeAccounts>[0], names: Parameters<typeof describeAccounts>[1], plan: StatementPlan): string {
  const who = describeAccounts(accounts, names)
  const period = statementPeriodText(accounts, plan)
  return [who.charAt(0).toUpperCase() + who.slice(1), period].filter(Boolean).join(' · ')
}

/** What the statement shows, as read, before she has approved anything. */
function readSentence(plan: StatementPlan): string {
  const spending = plan.spending
  if (spending && spending.read_count > 0) return `I read ${spending.read_count.toLocaleString('en-US')} ${spending.read_count === 1 ? 'purchase' : 'purchases'}, ${formatReviewMoney(spending.read_cents)}.`
  return `I read ${plan.total.toLocaleString('en-US')} ${plan.total === 1 ? 'line' : 'lines'}.`
}

/** What now counts toward her spending, from the lines she approved. */
function countedSentence(plan: StatementPlan): string {
  const spending = plan.spending
  if (spending && spending.counted_count > 0) return `${spending.counted_count.toLocaleString('en-US')} ${spending.counted_count === 1 ? 'purchase' : 'purchases'}, ${formatReviewMoney(spending.counted_cents)}, now ${spending.counted_count === 1 ? 'counts' : 'count'} in your spending.`
  return 'Nothing from this statement counts as spending.'
}
