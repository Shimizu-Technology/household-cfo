import { useEffect, useRef, useState, type ReactNode } from 'react'
import { fetchDocumentSourceReview, type TransactionDraft } from '../api'
import { sourceAccountLabel, sourceEventLabel, sourceLocator, sourceMoney, validateSourceReview, type SourceReview, type SourceReviewFilter } from '../lib/sourceReview'
import './StatementSourceReview.css'

export function StatementSourceReview({ importId, revisionId, refreshKey, renderExpenseDraft }: {
  importId: number; revisionId: number; refreshKey: string
  renderExpenseDraft: (draft: TransactionDraft) => ReactNode
}) {
  const [filter, setFilter] = useState<SourceReviewFilter>('all')
  const [page, setPage] = useState(1)
  const [attempt, setAttempt] = useState(0)
  const [selectedRow, setSelectedRow] = useState<number | null>(null)
  const [result, setResult] = useState<{ key: string; data?: SourceReview; error?: string } | null>(null)
  const heading = useRef<HTMLHeadingElement>(null)
  const requestKey = `${importId}:${revisionId}:${page}:${filter}:${attempt}:${refreshKey}`
  const data = result?.key === requestKey ? result.data : undefined
  const error = result?.key === requestKey ? result.error : undefined
  useEffect(() => {
    const controller = new AbortController()
    let live = true
    fetchDocumentSourceReview(importId, revisionId, page, filter, controller.signal).then((payload) => {
      validateSourceReview(payload, importId, revisionId, page, filter)
      if (live) setResult({ key: requestKey, data: payload })
    }).catch((failure: unknown) => {
      if (live) setResult({ key: requestKey, error: failure instanceof Error ? failure.message : 'Could not load statement rows.' })
    })
    return () => { live = false; controller.abort() }
  }, [importId, revisionId, page, filter, requestKey])

  function navigate(nextPage: number) {
    setPage(nextPage)
    setSelectedRow(null)
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
      <p className="source-review-boundary">Source accounting is awaiting participant review. Viewing rows or balanced arithmetic does not approve this source. Movements, transfers and card payments are not savings.</p>
      {data && <>
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
        <label>Show source rows<select aria-label="Filter statement rows" value={filter} onChange={(event) => { setFilter(event.target.value as SourceReviewFilter); setPage(1); setSelectedRow(null) }}>
          <option value="all">All rows</option><option value="posted">Posted movements</option><option value="unresolved">Unresolved rows</option><option value="informational">Informational rows</option>
        </select></label>
        <span>50 rows per page</span>
      </div>
      {!data && !error && <p role="status">Loading statement rows. Totals are unavailable until this page loads.</p>}
      {error && <div className="source-review-error" role="alert"><p>{error}</p><p>No rows from a different page or revision are shown.</p><button type="button" onClick={() => setAttempt((value) => value + 1)}>Retry statement page</button></div>}
      {data && <>
        <p className="source-review-page-status" role="status">{data.pagination.total_count === 0 ? '0 rows match this filter' : `Rows ${(page - 1) * 50 + 1}–${(page - 1) * 50 + data.events.length} of ${data.pagination.total_count}`} · Page {page} of {data.pagination.total_pages}</p>
        <ol className="source-event-list" aria-label="Statement source rows" start={(page - 1) * 50 + 1}>
          {data.events.map((event) => {
            const account = data.accounts.find((candidate) => candidate.id === event.financial_source_account_id)
            const linkedDraft = event.expense_projection_eligible ? event.transaction_draft : null
            return <li key={event.id} className={`source-event source-event-${event.row_kind}`}>
              <div className="source-event-main"><div><strong>{event.evidence?.merchant || `Source row ${event.position + 1}`}</strong><span>{sourceEventLabel(event)}</span></div><strong className="source-event-amount">{event.row_kind === 'informational' ? `${sourceMoney(event.evidence?.displayed_amount_cents)} (information)` : sourceMoney(event.signed_amount_cents, true)}</strong></div>
              <p>{event.posted_on ?? 'Posted date unknown'} · {sourceAccountLabel(account, event.financial_source_account_id)} · {sourceLocator(event)}</p>
              {event.authorized_on && event.authorized_on !== event.posted_on && <p>Authorized {event.authorized_on}</p>}
              {!event.evidence_available && <p>Row description evidence unavailable.</p>}
              {event.limitations.length > 0 && <p className="source-review-limitation">{event.limitations.map((item) => item.replaceAll('_', ' ')).join(' · ')}</p>}
              {event.funding_components.length > 0 && <p>Funding split: {event.funding_components.map((part) => `${data.accounts.some((candidate) => candidate.source_key === part.source_key) ? sourceAccountLabel(data.accounts.find((candidate) => candidate.source_key === part.source_key), event.financial_source_account_id) : 'Unidentified funding account'} ${sourceMoney(part.amount_cents)}`).join(' + ')}. Funding is not additional spending.</p>}
              <button type="button" className="source-event-details-toggle" aria-expanded={selectedRow === event.id} aria-controls={`source-event-details-${event.id}`} onClick={() => setSelectedRow(selectedRow === event.id ? null : event.id)}>{selectedRow === event.id ? 'Hide' : 'Inspect'} source row {event.position + 1}{linkedDraft ? ' & expense review' : ''}</button>
              {selectedRow === event.id && <div id={`source-event-details-${event.id}`} className="source-event-details">
                {event.evidence?.raw_description && <p>{event.evidence.raw_description}</p>}
                {event.evidence?.evidence && <p>{event.evidence.evidence}</p>}
                <p>Classification: {event.event_type.replaceAll('_', ' ')}. Source review: {event.review_state}. {event.expense_projection_eligible ? 'This row can propose an expense; approval below is separate from source accounting.' : 'This row does not propose an expense.'}</p>
                {linkedDraft ? renderExpenseDraft(linkedDraft) : <p>No expense review is attached to this source row.</p>}
              </div>}
            </li>
          })}
        </ol>
        <nav className="source-review-pagination" aria-label="Statement row pagination"><span>Page {page} of {data.pagination.total_pages}</span><div><button type="button" disabled={!data.pagination.has_previous} onClick={() => navigate(page - 1)}>Previous rows</button><button type="button" disabled={!data.pagination.has_next} onClick={() => navigate(page + 1)}>Next rows</button></div></nav>
      </>}
    </section>
  )
}
