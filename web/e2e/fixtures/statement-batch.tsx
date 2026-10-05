import { createRoot } from 'react-dom/client'
import { useRef, useState } from 'react'
import { StatementBatchReview } from '../../src/components/StatementBatchReview'
import { participantReviewFixture } from '../sourceReviewFixtures'
import type { PendingSourceDraft, ReviewedFacts, SourceReviewAction } from '../../src/lib/participantSourceReview'
import '../../src/index.css'
import '../../src/components/StatementSourceReview.css'

// Pure synthetic component rehearsal. These callbacks model account-version
// conflicts, not a real API, provider, account approval or financial advice.
function initial() {
  const source = participantReviewFixture()
  const context = source.participant_review!
  const events = [4003, 4005, 4006, 4007, 4008, 4009].map((id, index) => ({ ...source.events.find((event) => event.id === id)!, financial_source_account_id: 501 + Math.floor(index / 2) }))
  context.accounts = [0, 1, 2].map((index) => ({ ...structuredClone(context.accounts[0]), source_account_id: 501 + index,
    head: { id: 80 + index, approved_version_id: 100 + index * 100, lock_version: 1 },
    approved: { ...structuredClone(context.accounts[0].approved!), id: 100 + index * 100, digest: `account-v1-${index}`, version_number: 1,
      tracked_account: { id: 2, label: 'Fictional shared checking', account_basis: 'asset' as const, account_id: null } } }))
  for (const [index, event] of events.entries()) {
    const facts: ReviewedFacts = { source_account_identity_version_id: 100 + Math.floor(index / 2) * 100,
      disposition: 'include', event_type: event.event_type, signed_amount_cents: -1_000 - index, purchase_amount_cents: 1_000 + index,
      posted_on: '2026-09-15', authorized_on: '2026-09-14', merchant: `Reviewed fictional row ${index + 1}`,
      budget_category_id: 10, overlap_disposition: 'distinct', external_reference: `fictional-ref-${index}`, matched_version_id: null }
    context.rows[event.id] = { head: { id: event.id + 1_000, approved_version_id: event.id + 20_000, lock_version: 1 }, pending: null,
      approved: { id: event.id + 20_000, digest: `approved-v1-${event.id}`, version_number: 1, facts, reason: 'Original fictional row review',
        projection: { action: 'create' }, actual: { id: event.id + 30_000, digest: `actual-${event.id}`, amount_cents: facts.purchase_amount_cents! } } }
  }
  context.coverage.approved_rows = 6
  return { context, events }
}
export function Fixture() {
  const [seed] = useState(initial)
  const [context, setContext] = useState(seed.context)
  const [running, setRunning] = useState(false)
  const [requests, setRequests] = useState<Array<{ action: SourceReviewAction; input: object }>>([])
  const [error, setError] = useState('')
  const changes = useRef(new Map<number, PendingSourceDraft | 'approved'>())
  async function mutate(action: SourceReviewAction, input: object) {
    setRequests((previous) => [...previous, { action, input }])
    if (action === 'stage') {
      const payload = input as { event_id: number; facts: ReviewedFacts; projection: { action: string }; reason: string }
      const event = seed.events.find((event) => event.id === payload.event_id)!
      const identity = context.accounts.find((account) => account.source_account_id === event.financial_source_account_id)!.approved!
      const original = context.rows[event.id].approved!.facts
      if (JSON.stringify(payload.facts) !== JSON.stringify({ ...original, source_account_identity_version_id: identity.id }) || payload.projection.action !== 'none') {
        setError('Review this source account’s current identity before approving its rows. Financial facts and spending must remain unchanged.')
        return false
      }
      changes.current.set(event.id, { id: event.id + 10_000, digest: `proposal-v2-${event.id}`, lock_version: 1, status: 'pending',
        facts: payload.facts, projection: payload.projection, reason: payload.reason,
        recognized_account: { identity_version_id: identity.id, tracked_account_id: 2, label: identity.tracked_account.label, account_basis: 'asset', account_id: null, current: true } })
    } else if (action === 'approve') {
      const payload = input as { draft_id: number; draft_digest: string; draft_lock_version: number }
      const event = seed.events.find((event) => context.rows[event.id].pending?.id === payload.draft_id)!
      const pending = context.rows[event.id].pending!
      const identity = context.accounts.find((account) => account.source_account_id === event.financial_source_account_id)!.approved!
      if (pending.facts.source_account_identity_version_id !== identity.id || pending.digest !== payload.draft_digest || pending.lock_version !== payload.draft_lock_version) { setError('Stale saved proposal rejected.'); return false }
      changes.current.set(event.id, 'approved')
    }
    return true
  }
  function onRunning(value: boolean) {
    setRunning(value)
    // The production parent refreshes only when its serial batch ends.
    if (!value) setContext((previous) => {
      const next = structuredClone(previous)
      for (const [id, change] of changes.current) {
        const row = next.rows[id]
        if (change === 'approved') {
          row.approved = { ...row.approved!, id: id + 40_000, digest: `approved-v2-${id}`, version_number: 2, facts: row.pending!.facts,
            reason: row.pending!.reason, projection: row.pending!.projection }
          row.pending = null
          row.head = { ...row.head, approved_version_id: row.approved.id, lock_version: 2 }
        } else row.pending = change
      }
      changes.current.clear()
      return next
    })
  }
  function correctAccounts() {
    setContext((previous) => ({ ...previous, accounts: previous.accounts.map((account) => ({ ...account,
      head: { ...account.head, approved_version_id: account.approved!.id + 1, lock_version: 2 },
      approved: { ...account.approved!, id: account.approved!.id + 1, digest: `${account.approved!.digest}-corrected`, version_number: 2,
        statement_facts: { ...account.approved!.statement_facts, period_start_on: '2026-09-01', period_end_on: '2026-09-30' } } })) }))
  }
  function oldPending() {
    setContext((previous) => {
      const next = structuredClone(previous)
      for (const event of seed.events) {
        next.rows[event.id].pending = { id: event.id + 10_000, digest: `historical-v1-proposal-${event.id}`, lock_version: 1, status: 'pending',
          facts: structuredClone(seed.context.rows[event.id].approved!.facts), projection: { action: 'create' }, reason: 'Historical saved v1 proposal' }
      }
      return next
    })
  }
  return <main style={{ maxWidth: '64rem', margin: '0 auto', padding: '1rem', minWidth: 0 }}>
    <h1>Fictional statement batch review</h1><p>Synthetic component fixture only. Six reviewed rows, three source fragments, one recognized account. No API, provider or approved spending is written.</p>
    <button type="button" disabled={running || context.accounts[0].approved!.version_number === 2} onClick={correctAccounts}>Correct reviewed account identities to version 2</button>
    <button type="button" disabled={running} onClick={oldPending}>Load saved proposal on old identity</button>
    <p role="status" aria-label="Fixture submissions">{requests.length} synthetic review requests submitted</p>
    {error && <p role="alert">{error}</p>}
    <StatementBatchReview events={seed.events} selected={seed.events.map((event) => event.id)} context={context} mutate={mutate} disabled={running} onRunning={onRunning} />
    <details><summary>Inspect synthetic request payloads</summary><pre data-testid="fixture-requests" style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{JSON.stringify(requests)}</pre></details>
  </main>
}
createRoot(document.getElementById('root')!).render(<Fixture />)
