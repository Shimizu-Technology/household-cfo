import { useEffect, useRef, useState } from 'react'
import { sourceBasisLabel, sourceDispositionLabel, sourceLocator, sourceMoney, sourceOverlapLabel, sourceTypeLabel, type SourceEvent } from '../lib/sourceReview'
import type { ParticipantSourceReview, ReviewedFacts, SourceReviewAction } from '../lib/participantSourceReview'

type Mutation = (action: SourceReviewAction, input: object) => Promise<boolean>
export function StatementBatchReview({ events, selected, context, mutate, disabled, onRunning }: {
  events: SourceEvent[]; selected: number[]; context: ParticipantSourceReview; mutate: Mutation; disabled: boolean; onRunning: (running: boolean) => void
}) {
  const [category, setCategory] = useState('keep')
  const [reason, setReason] = useState('')
  const [confirmation, setConfirmation] = useState<string | null>(null)
  const [status, setStatus] = useState('')
  const rows = events.filter((event) => selected.includes(event.id))
  const proposed = rows.map((event) => {
    const row = context.rows[event.id]
    const identity = context.accounts.find((account) => account.source_account_id === event.financial_source_account_id)?.approved
    const facts: ReviewedFacts = row?.approved?.facts ?? {
      source_account_identity_version_id: identity?.id ?? 0, disposition: 'include', event_type: event.event_type,
      signed_amount_cents: event.signed_amount_cents, purchase_amount_cents: event.expense_amount_cents,
      posted_on: event.posted_on, authorized_on: event.authorized_on, merchant: event.evidence?.merchant ?? null,
      budget_category_id: null, overlap_disposition: 'new', external_reference: null,
    }
    const expense = ['purchase', 'fee', 'interest'].includes(facts.event_type) && (facts.signed_amount_cents ?? 0) < 0
    // A new proposal uses the account identity being reviewed now. Existing
    // approved facts and historical pending proposals remain immutable inputs.
    return { event, row, identity, expense, facts: { ...facts,
      source_account_identity_version_id: identity?.id ?? 0,
      budget_category_id: expense && category !== 'keep' ? category ? Number(category) : null : facts.budget_category_id,
    } }
  })
  const reviewContext = JSON.stringify({ actor: context.actor_scope, revision: context.coverage.revision_id,
    coverage: context.coverage.content_digest, categories: context.categories, category, reason,
    rows: proposed.map((item) => ({ event_id: item.event.id, revision_id: item.event.financial_extraction_revision_id,
      source_account_id: item.event.financial_source_account_id, position: item.event.position,
      identity: item.identity, head: item.row?.head, approved: item.row?.approved, pending: item.row?.pending, facts: item.facts })),
  })
  const lifecycle = useRef({ mounted: true, generation: 0 })
  useEffect(() => {
    const state = lifecycle.current
    state.mounted = true
    state.generation += 1
    return () => { state.mounted = false; state.generation += 1 }
  }, [])
  const activeContext = useRef(reviewContext)
  useEffect(() => { activeContext.current = reviewContext }, [reviewContext])
  const checked = confirmation === reviewContext
  const stageReady = proposed.length > 0 && proposed.every((item) => item.row && item.identity && !item.row.pending &&
    item.facts.disposition === 'include' && item.facts.event_type !== 'unknown' && item.facts.signed_amount_cents && item.facts.posted_on &&
    (!item.expense || item.facts.merchant && item.facts.purchase_amount_cents))
  const approveReady = proposed.length > 0 && proposed.every((item) => {
    const pending = item.row?.pending
    return item.identity && pending && pending.facts.source_account_identity_version_id === item.identity.id &&
      pending.recognized_account?.current !== false && (pending.facts.disposition !== 'match' || pending.matched_target?.current === true)
  })
  async function run(action: 'stage' | 'approve') {
    if (!lifecycle.current.mounted || disabled || !checked || !(action === 'stage' ? stageReady : approveReady)) return
    const confirmedContext = reviewContext
    const generation = lifecycle.current.generation
    onRunning(true); setStatus('')
    let completed = 0
    try {
      for (const item of proposed) {
        if (!lifecycle.current.mounted || lifecycle.current.generation !== generation) return
        if (activeContext.current !== confirmedContext) {
          setStatus(`Stopped after ${completed} of ${rows.length}. The displayed review context changed. Check the current accounts and rows before continuing. Remaining rows have not been submitted.`)
          return
        }
        const pending = item.row?.pending
        const input = action === 'approve'
          ? { draft_id: pending!.id, draft_digest: pending!.digest, draft_lock_version: pending!.lock_version }
          : { event_id: item.event.id, base_version_id: item.row?.head.approved_version_id ?? null,
            base_lock_version: item.row?.head.lock_version ?? 0, expected_pending_draft: null, facts: item.facts, projection: { action: 'none' }, reason }
        if (!await mutate(action, input)) {
          setStatus(`Stopped after ${completed} of ${rows.length}. Resolve the request or error before continuing. Remaining rows have not been submitted.`)
          return
        }
        completed += 1
      }
      if (!lifecycle.current.mounted || lifecycle.current.generation !== generation) return
      setConfirmation(null)
      setStatus(`${completed} of ${rows.length} ${action === 'stage' ? 'proposals saved for review' : 'saved proposals approved'}.`)
    } finally { onRunning(false) }
  }
  if (!rows.length) return null
  return <section className="source-batch-review" aria-label="Review explicitly selected rows">
    <h6>{rows.length} explicitly selected rows on this page</h6>
    <p>Only your selected rows will be submitted, one at a time. Saving these proposals does not add spending. Unknown or informational rows require individual review; nothing is silently classified or dropped.</p>
    <form className="source-review-form"><fieldset disabled={disabled}><legend>Review each exact row</legend>
      <label>Spending category for selected purchase proposals<select value={category} onChange={(event) => setCategory(event.target.value)}>
        <option value="keep">Keep each row’s reviewed category</option><option value="">Explicitly uncategorized</option>
        {context.categories.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}
      </select></label>
      {proposed.map((item) => {
        const pending = item.row?.pending
        const facts = pending?.facts ?? item.facts
        const projection = pending?.projection.action ?? 'none'
        const stalePending = Boolean(pending && (facts.source_account_identity_version_id !== item.identity?.id || pending.recognized_account?.current === false))
        return <article className="source-link-member" key={item.event.id}>
          <strong>Source row {item.event.position + 1}</strong>
          <p>Current reviewed account: {item.identity?.tracked_account.label ?? 'Account not reviewed'} · {sourceBasisLabel(item.identity?.tracked_account.account_basis)}</p>
          {pending && <p className={stalePending ? 'source-row-review-status' : undefined}>Saved proposal account: {pending.recognized_account?.label ?? 'Account details unavailable'}{stalePending ? ' · differs from the current reviewed account and requires individual review before approval.' : ' · matches the current reviewed account.'}</p>}
          <p>{sourceDispositionLabel(facts.disposition)} · {sourceTypeLabel(facts.event_type)} · {facts.merchant ?? 'Merchant unknown'} · {sourceMoney(facts.signed_amount_cents, true)} · {facts.posted_on ?? 'Date unknown'} · Complete purchase {sourceMoney(facts.purchase_amount_cents)}</p>
          <p>Category: {context.categories.find((category) => category.id === facts.budget_category_id)?.name ?? 'Explicitly uncategorized'} · Duplicate check: {sourceOverlapLabel(facts.overlap_disposition)} · Spending: {projection === 'none' ? `unchanged${item.row?.approved?.actual ? ` at ${sourceMoney(item.row.approved.actual.amount_cents)}` : ' (none recorded)'}` : projection === 'void' ? `remove existing ${sourceMoney(item.row?.approved?.actual?.amount_cents ?? null)}` : `${projection === 'replace' ? `replace existing ${sourceMoney(item.row?.approved?.actual?.amount_cents ?? null)} with` : 'create'} ${sourceMoney(facts.purchase_amount_cents)} on ${facts.posted_on ?? 'unknown date'}`}</p>
          {pending?.matched_target && <p>Matched source: {pending.matched_target.source?.filename ?? 'Retained source'} · {sourceLocator({ locator: pending.matched_target.source?.locator ?? {} } as SourceEvent)} · {pending.matched_target.recognized_account?.label ?? 'Account unknown'} · {pending.matched_target.facts.merchant} · {sourceMoney(pending.matched_target.facts.signed_amount_cents, true)} · {pending.matched_target.facts.posted_on}</p>}
          {pending && <p>Saved review note: {pending.reason}</p>}
          <details className="source-review-technical"><summary>Review record details</summary>
            <p>Current account review: version {item.identity?.version_number ?? 'unknown'} · identity ID {item.identity?.id ?? 'unknown'}. Saved facts account identity ID: {facts.source_account_identity_version_id}.</p>
            <p>Authorized: {facts.authorized_on ?? 'Unknown'} · Statement reference: {facts.external_reference ?? 'None'} · Matched approved row ID: {facts.matched_version_id ?? 'None'}.</p>
            {pending?.matched_target && <p>Matched approved version: {pending.matched_target.version_number}.</p>}
          </details>
        </article>
      })}
      <label>Selected-row review note<input maxLength={500} value={reason} onChange={(event) => setReason(event.target.value)} /></label>
      <label className="source-review-check"><input type="checkbox" checked={checked} onChange={(event) => setConfirmation(event.target.checked ? reviewContext : null)} />I checked every displayed account, classification, date, signed amount, complete purchase and spending effect for these selected rows.</label>
      <div className="source-review-pagination">
        <button type="button" disabled={!checked || !reason.trim() || !stageReady} onClick={() => { void run('stage') }}>Save selected row proposals</button>
        <button type="button" className="source-review-primary" disabled={!checked || !approveReady} onClick={() => { void run('approve') }}>Approve selected saved proposals</button>
      </div>
      {!stageReady && !approveReady && <p>Use individual review to resolve missing facts, account identity or mixed pending states before a batch action.</p>}
    </fieldset></form>{status && <p role="status">{status}</p>}
  </section>
}
