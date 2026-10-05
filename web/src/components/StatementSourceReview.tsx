import { useEffect, useRef, useState, type ReactNode } from 'react'
import { fetchDocumentSourceReview, type TransactionDraft } from '../api'
import { sourceAccountLabel, sourceEventLabel, sourceLocator, sourceMoney, validateSourceReview, type SourceReview, type SourceReviewFilter } from '../lib/sourceReview'
import { StatementBatchReview } from './StatementBatchReview'
import { StatementAccountReview, StatementCoverageReview, StatementRowEditor } from './StatementReviewControls'
import { isStatementReviewActor } from '../lib/statementReviewRecovery'
import { useStatementReviewMutation } from '../lib/useStatementReviewMutation'
import './StatementSourceReview.css'

export function StatementSourceReview({ importId, revisionId, refreshKey, renderExpenseDraft }: {
  importId: number; revisionId: number; refreshKey: string
  renderExpenseDraft: (draft: TransactionDraft) => ReactNode
}) {
  const [batchSelected, setBatchSelected] = useState<number[]>([])
  const batchRunning = useRef(false)
  const refreshAfterBatch = useRef(false)
  const [filter, setFilter] = useState<SourceReviewFilter>('all')
  const [page, setPage] = useState(1)
  const [attempt, setAttempt] = useState(0)
  const [selectedRow, setSelectedRow] = useState<number | null>(null)
  const [result, setResult] = useState<{ key: string; data?: SourceReview; error?: string } | null>(null)
  const restoreFocus = useRef(false)
  const heading = useRef<HTMLHeadingElement>(null)
  const requestKey = `${importId}:${revisionId}:${page}:${filter}:${attempt}:${refreshKey}`
  const mutation = useStatementReviewMutation({ importId, revisionId, scope: result?.data?.participant_review?.actor_scope, refresh: () => { restoreFocus.current = true; if (batchRunning.current) refreshAfterBatch.current = true; else setAttempt((value) => value + 1) } })
  const scoped = result?.data?.participant_review
  const actorReady = !scoped || Boolean(scoped.actor_scope && isStatementReviewActor(scoped.actor_scope))
  const data = !mutation.accessDenied && actorReady && result?.key === requestKey ? result.data : undefined
  const error = result?.key === requestKey ? result.error : undefined
  useEffect(() => {
    const controller = new AbortController()
    let live = true
    fetchDocumentSourceReview(importId, revisionId, page, filter, controller.signal).then((payload) => {
      validateSourceReview(payload, importId, revisionId, page, filter)
      if (payload.participant_review && (!payload.participant_review.actor_scope || !Number.isSafeInteger(payload.participant_review.actor_scope.user_id) || !Number.isSafeInteger(payload.participant_review.actor_scope.household_id))) throw new Error('The private statement review scope is unavailable. Refresh before continuing.')
      if (live) setResult({ key: requestKey, data: payload })
    }).catch((failure: unknown) => {
      if (live) setResult({ key: requestKey, error: failure instanceof Error ? failure.message : 'Could not load statement rows.' })
    })
    return () => { live = false; controller.abort() }
  }, [importId, revisionId, page, filter, requestKey])

  useEffect(() => {
    if (data && restoreFocus.current) { restoreFocus.current = false; const target = document.getElementById(`source-event-details-${selectedRow}`); (target ?? heading.current)?.focus() }
  }, [data, selectedRow])

  function navigate(nextPage: number) {
    setPage(nextPage)
    setSelectedRow(null)
    setBatchSelected([])
    heading.current?.focus()
  }
  const accounting = data?.revision.reconciliation
  const pages = accounting?.page_coverage
  const census = accounting?.row_census
  return (
    <section className="statement-source-review" aria-label="Statement source accounting">
      <div className="source-review-heading">
        <h5 ref={heading} tabIndex={-1}>Statement rows & coverage</h5>
        <span>Revision {data?.revision.revision_number ?? 'loading'}</span>
      </div>
      <p className="source-review-boundary">{data?.participant_review?.approved_coverage?.current ? `Statement coverage approved with ${data.participant_review.approved_coverage.status} status.` : 'Source accounting is awaiting participant review.'} Viewing rows or balanced arithmetic does not approve this source. Movements, transfers and card payments are not savings.</p>
      {mutation.pendingRequest && <p role="status">An earlier statement request ({mutation.pendingRequest.action}, upload {mutation.pendingRequest.importId}) must be resolved before further changes. Request identifier: {mutation.pendingRequest.key}</p>}
      {mutation.checkStatus && <button type="button" disabled={mutation.pendingRequest?.working} onClick={() => { void mutation.checkStatus?.() }}>Check earlier review result</button>}
      {mutation.error && <div role="alert"><p>{mutation.error}</p>{mutation.retry && <><p>The result is uncertain. Retry the same request before making another change.</p><button type="button" onClick={() => { void mutation.retry?.() }}>Retry the same review request</button></>}</div>}
      {!mutation.accessDenied && <button type="button" disabled={mutation.busy} onClick={() => setAttempt((value) => value + 1)}>Refresh statement review</button>}
      {data && <>
        {data.participant_review && <StatementAccountReview context={data.participant_review} accounts={data.accounts} mutate={mutation.mutate} disabled={mutation.busy} />}

        <p className="source-review-counts" role="status">{data.counts.all} source rows · {data.counts.posted} posted · {data.counts.informational} informational · {data.counts.unresolved} unresolved. {data.counts.pending_transaction_drafts} expense reviews remaining · {data.counts.resolved_transaction_drafts} resolved.</p>
        <p className="source-review-source-state">{data.revision.source_available ? 'Original file available via Preview original above.' : 'Original file removed or unavailable. Extracted accounting remains; source evidence may be unavailable.'}</p>
        <details className="source-coverage-details">
          <summary>Account balances, period & extraction coverage</summary>
          <dl className="source-coverage-facts">
            <div><dt>PDF pages</dt><dd>{pages?.processed?.length ?? 0} processed / {pages?.expected ?? 'unknown'} expected · {pages?.all_processed === true ? 'All expected pages processed' : pages?.all_processed === false ? 'Incomplete page coverage' : 'Page completeness unknown'}</dd></div>
            <div><dt>Row census</dt><dd>{census?.represented ?? 'Unknown'} represented / {census?.reported ?? 'unknown'} reported · {census?.matches_reported === true ? 'Counts match' : census?.matches_reported === false ? 'Counts differ' : 'Printed row total unknown'}</dd></div>
            <div><dt>Sheets</dt><dd>{accounting?.sheet_coverage?.processed?.length ?? 0} processed / {accounting?.sheet_coverage?.expected ?? 'unknown'} expected</dd></div>
          </dl>
          {data.accounts.length === 0 && <p>No account header was identified. Account basis and balances are unknown.</p>}
          {data.accounts.map((account) => {
            const check = accounting?.accounts.find((entry) => entry.source_key === account.source_key)
            return <article className="source-account" key={account.id}>
              <h6>{sourceAccountLabel(account, account.id)}</h6>
              <p>{account.account_basis === 'asset' ? 'Asset account · outflows reduce this balance; inflows increase it.' : account.account_basis === 'liability' ? 'Liability account · outflows increase the amount owed; inflows reduce it.' : 'Account basis unknown · balance direction cannot be verified.'}</p>
              <dl className="source-coverage-facts">
                <div><dt>Statement period</dt><dd>{account.period_start_on ?? 'Unknown start'} — {account.period_end_on ?? 'unknown end'}</dd></div>
                <div><dt>Opening / closing</dt><dd>{sourceMoney(account.opening_balance_cents)} / {sourceMoney(account.closing_balance_cents)}</dd></div>
                <div><dt>Balance residual</dt><dd>{sourceMoney(check?.balance_residual_cents)} · {check?.arithmetic_balanced === true ? 'Arithmetic balanced; classification review still pending' : 'Not verified as balanced'}</dd></div>
                <div><dt>Printed debits / credits</dt><dd>{sourceMoney(account.printed_debit_cents)} / {sourceMoney(account.printed_credit_cents)}</dd></div>
                <div><dt>Debit / credit residual</dt><dd>{sourceMoney(check?.debit_residual_cents)} / {sourceMoney(check?.credit_residual_cents)}</dd></div>
                <div><dt>Account row count</dt><dd>{check?.represented_rows ?? 'Unknown'} represented / {account.printed_row_count ?? 'unknown'} printed · {check?.row_count_matches === true ? 'Counts match' : check?.row_count_matches === false ? 'Counts differ' : 'Not verified'}</dd></div>
              </dl>
              {!account.evidence_available && <p>Account header evidence unavailable.</p>}
              {Array.from(new Set([...account.limitations, ...(check?.limitations ?? [])])).map((limitation) => <p className="source-review-limitation" key={limitation}>{limitation.replaceAll('_', ' ')}</p>)}
            </article>
          })}
          {accounting?.limitations.map((limitation) => <p className="source-review-limitation" key={limitation}>{limitation.replaceAll('_', ' ')}</p>)}
        </details>
      </>}
      <div className="source-review-toolbar">
        <label>Show source rows<select aria-label="Filter statement rows" value={filter} disabled={mutation.busy} onChange={(event) => { setFilter(event.target.value as SourceReviewFilter); setPage(1); setSelectedRow(null); setBatchSelected([]) }}>
          <option value="all">All rows</option><option value="posted">Posted movements</option><option value="unresolved">Extraction unresolved rows</option><option value="informational">Informational rows</option>
        </select></label>
        <span>50 rows per page</span>
      </div>
      {!mutation.accessDenied && !data && !error && <p role="status">Loading statement rows. Totals are unavailable until this page loads.</p>}
      {error && <div className="source-review-error" role="alert"><p>{error}</p><p>No rows from a different page or revision are shown.</p><button type="button" onClick={() => setAttempt((value) => value + 1)}>Retry statement page</button></div>}
      {data && <>
        <p className="source-review-page-status" role="status">{data.pagination.total_count === 0 ? '0 rows match this filter' : `Rows ${(page - 1) * 50 + 1}–${(page - 1) * 50 + data.events.length} of ${data.pagination.total_count}`} · Page {page} of {data.pagination.total_pages}</p>
        <p>Filters describe the original extraction. Reviewed corrections and pending proposals are labeled separately below.</p>
        <ol className="source-event-list" aria-label="Statement source rows" start={(page - 1) * 50 + 1}>
          {data.events.map((event) => {
            const account = data.accounts.find((candidate) => candidate.id === event.financial_source_account_id)
            const reviewed = data.participant_review?.rows[event.id]
            const linkedDraft = event.expense_projection_eligible ? event.transaction_draft : null
            return <li key={event.id} className={`source-event source-event-${event.row_kind}`}>
              {reviewed && <label className="source-review-check"><input type="checkbox" disabled={mutation.busy} checked={batchSelected.includes(event.id)} onChange={(change) => setBatchSelected(change.target.checked ? [...batchSelected, event.id] : batchSelected.filter((id) => id !== event.id))} />Select source row {event.position + 1} for explicit batch review</label>}
              {reviewed && <p className="source-row-review-status">{reviewed.pending ? 'Pending proposal' : reviewed.approved ? `Approved version ${reviewed.approved.version_number}${reviewed.approved.current === false ? ' · identity changed; review needed' : ''}` : 'Needs participant review'}{reviewed.approved && ` · Current reviewed facts: ${reviewed.approved.facts.merchant ?? 'No merchant'} · ${reviewed.approved.facts.event_type.replaceAll('_', ' ')} · ${sourceMoney(reviewed.approved.facts.signed_amount_cents, true)} · ${reviewed.approved.facts.posted_on ?? 'Date unknown'}`}</p>}
              <div className="source-event-main" aria-label="Original extracted facts"><div><strong>{event.evidence?.merchant || `Source row ${event.position + 1}`}</strong><span>{sourceEventLabel(event)}</span></div><strong className="source-event-amount">{event.row_kind === 'informational' ? `${sourceMoney(event.evidence?.displayed_amount_cents)} (information)` : sourceMoney(event.signed_amount_cents, true)}</strong></div>
              <p>{event.posted_on ?? 'Posted date unknown'} · {sourceAccountLabel(account, event.financial_source_account_id)} · {sourceLocator(event)}</p>
              {event.authorized_on && event.authorized_on !== event.posted_on && <p>Authorized {event.authorized_on}</p>}
              {!event.evidence_available && <p>Row description evidence unavailable.</p>}
              {event.limitations.length > 0 && <p className="source-review-limitation">{event.limitations.map((item) => item.replaceAll('_', ' ')).join(' · ')}</p>}
              {event.funding_components.length > 0 && <p>Funding split: {event.funding_components.map((part) => `${data.accounts.some((candidate) => candidate.source_key === part.source_key) ? sourceAccountLabel(data.accounts.find((candidate) => candidate.source_key === part.source_key), event.financial_source_account_id) : 'Unidentified funding account'} ${sourceMoney(part.amount_cents)}`).join(' + ')}. Funding is not additional spending.</p>}
              <button type="button" className="source-event-details-toggle" aria-expanded={selectedRow === event.id} aria-controls={`source-event-details-${event.id}`} disabled={mutation.busy} onClick={() => setSelectedRow(selectedRow === event.id ? null : event.id)}>{selectedRow === event.id ? 'Hide' : 'Inspect'} source row {event.position + 1}{linkedDraft ? ' & expense review' : ''}</button>
              {selectedRow === event.id && <div id={`source-event-details-${event.id}`} className="source-event-details" tabIndex={-1}>
                {event.evidence?.raw_description && <p>{event.evidence.raw_description}</p>}
                {event.evidence?.evidence && <p>{event.evidence.evidence}</p>}
                <p>Original extraction classification: {event.event_type.replaceAll('_', ' ')}. Original source review: {event.review_state}. {event.expense_projection_eligible ? 'This row can propose an expense; approval below is separate from source accounting.' : 'This row does not propose an expense.'}</p>
                {data.participant_review ? <StatementRowEditor importId={importId} context={data.participant_review} event={event} mutate={mutation.mutate} disabled={mutation.busy} /> : linkedDraft ? renderExpenseDraft(linkedDraft) : <p>No expense review is attached to this source row.</p>}
              </div>}
            </li>
          })}
        </ol>
        {data.participant_review && <StatementBatchReview key={`${batchSelected.join(',')}:${batchSelected.map((id) => data.participant_review?.rows[id]?.pending?.digest ?? data.participant_review?.rows[id]?.approved?.digest ?? 'new').join(',')}`} events={data.events} selected={batchSelected} context={data.participant_review} mutate={mutation.mutate} disabled={mutation.busy} onRunning={(running) => { batchRunning.current = running; if (!running && refreshAfterBatch.current) { refreshAfterBatch.current = false; setAttempt((value) => value + 1) } }} />}
        {data.participant_review && <StatementCoverageReview key={data.participant_review.coverage.content_digest} context={data.participant_review} mutate={mutation.mutate} disabled={mutation.busy} />}
        <nav className="source-review-pagination" aria-label="Statement row pagination"><span>Page {page} of {data.pagination.total_pages}</span><div><button type="button" disabled={mutation.busy || !data.pagination.has_previous} onClick={() => navigate(page - 1)}>Previous rows</button><button type="button" disabled={mutation.busy || !data.pagination.has_next} onClick={() => navigate(page + 1)}>Next rows</button></div></nav>
      </>}
    </section>
  )
}
