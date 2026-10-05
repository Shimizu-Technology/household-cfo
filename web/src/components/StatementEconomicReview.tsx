import { ReviewedSourcePreview } from './ReviewedSourcePreview'
import { useEffect, useState, type FormEvent } from 'react'
import { fetchSourceDuplicateCandidates } from '../api'
import { sourceLocator, sourceMoney, type SourceEvent } from '../lib/sourceReview'
import { statementCents, statementDollars, type ParticipantSourceReview, type ReviewedEconomicGroup, type ReviewedRow, type SourceReviewAction } from '../lib/participantSourceReview'
type Mutation = (action: SourceReviewAction, input: object) => Promise<unknown>
type Member = { row: ReviewedRow; role: 'movement' | 'purchase' | 'funding' | 'original_purchase' | 'refund'; amount: string }
function RowFacts({ row }: { row: ReviewedRow }) {
  return <span>{row.recognized_account?.label ?? 'Reviewed account'} · {row.recognized_account?.account_basis ?? 'basis unavailable'} · {row.facts.merchant ?? 'Reviewed movement'} · {row.facts.event_type.replaceAll('_', ' ')} · {sourceMoney(row.facts.signed_amount_cents, true)} · {row.facts.posted_on ?? 'Unknown date'} · complete purchase {sourceMoney(row.facts.purchase_amount_cents)} · {row.source?.filename ?? 'Retained source'} · {sourceLocator({ locator: row.source?.locator ?? {} } as SourceEvent)} · approved version {row.version_number}</span>
}
export function StatementEconomicReview({ importId, eventId, row, context, mutate, disabled }: { importId: number; eventId: number; row: ReviewedRow; context: ParticipantSourceReview; mutate: Mutation; disabled: boolean }) {
  const groups = (context.economic_groups ?? []).filter((group) => group.approved?.members.some((member) => member.record.id === row.id))
  return <section className="source-economic-review" aria-label="Link related reviewed movements">
    {row.facts.disposition === 'include' && <><h6>Link funding, transfers or refunds</h6><p>Link approved physical rows that describe the same economic event. Links do not record savings or move money. A bank or card payment is not another purchase.</p>
    {groups.map((group) => <details key={group.id}><summary>{group.approved?.kind.replaceAll('_', ' ')} · version {group.approved?.version_number} · {group.approved?.current ? 'Current' : 'Needs review'}</summary>{group.approved?.members.map((member) => <p key={member.record.id}>{member.role} · {sourceMoney(member.allocation_cents)} · <RowFacts row={member.record} /></p>)}<LinkForm key={`${group.id}:${group.head.lock_version}`} importId={importId} eventId={eventId} row={row} mutate={mutate} disabled={disabled} group={group} /></details>)}
    <details><summary>Create a related-movement link</summary><LinkForm importId={importId} eventId={eventId} row={row} mutate={mutate} disabled={disabled} /></details>
    </>}<ProjectionForm key={`${row.id}:${row.actual?.digest ?? ''}`} row={row} groups={groups} mutate={mutate} disabled={disabled} />
  </section>
}
function LinkForm({ importId, eventId, row, group, mutate, disabled }: { importId: number; eventId: number; row: ReviewedRow; group?: ReviewedEconomicGroup; mutate: Mutation; disabled: boolean }) {
  const [kind, setKind] = useState<'transfer' | 'purchase_funding' | 'refund'>(group?.approved?.kind ?? 'transfer')
  const [members, setMembers] = useState<Member[]>(group?.approved?.members.map((member) => ({ row: member.record, role: member.role, amount: statementDollars(member.allocation_cents) })) ?? [{ row, role: 'movement', amount: statementDollars(Math.abs(row.facts.signed_amount_cents ?? 0)) }])
  const [cursor, setCursor] = useState<number | null>(null)
  const [next, setNext] = useState<number | null>(null)
  const [history, setHistory] = useState<Array<number | null>>([])
  const [attempt, setAttempt] = useState(0)
  const [candidates, setCandidates] = useState<ReviewedRow[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [reason, setReason] = useState('')
  const [checked, setChecked] = useState(false)
  useEffect(() => {
    const controller = new AbortController(); let live = true
    fetchSourceDuplicateCandidates(importId, eventId, cursor, controller.signal, { filter: 'link' }).then((page) => { if (live) { setCandidates(page.records); setNext(page.next_cursor); setLoading(false); setError(null) } }).catch((failure: unknown) => { if (live) { setError(failure instanceof Error ? failure.message : 'Related rows unavailable.'); setLoading(false) } })
    return () => { live = false; controller.abort() }
  }, [importId, eventId, cursor, attempt])
  const roles = kind === 'transfer' ? ['movement'] : kind === 'purchase_funding' ? ['purchase','funding'] : ['original_purchase','refund']
  async function submit(event: FormEvent) {
    event.preventDefault(); setError(null)
    try {
      if (members.length < 2 || members.length > 12) throw new Error('Select 2–12 reviewed rows for this link.')
      const allocations = members.map((member) => ({ source_review_version_id: member.row.id, role: member.role, allocation_cents: statementCents(member.amount, false) }))
      if (allocations.some((member) => member.allocation_cents! <= 0)) throw new Error('Each allocation must be a positive amount.')
      await mutate('economic_link', { group_id: group?.id ?? null, base_version_id: group?.head.approved_version_id ?? null, base_lock_version: group?.head.lock_version ?? 0, kind, members: allocations, reason })
    } catch (failure) { setError(failure instanceof Error ? failure.message : 'Check the selected link.') }
  }
  return <form className="source-review-form" onSubmit={(event) => { void submit(event) }}><fieldset disabled={disabled}><legend>{group ? 'Correct this link' : 'Prepare an explicit link'}</legend>
    <label>Link type<select value={kind} onChange={(event) => { const value = event.target.value as typeof kind; setKind(value); setMembers([{ row, role: value === 'purchase_funding' ? 'purchase' : value === 'refund' ? 'original_purchase' : 'movement', amount: statementDollars(Math.abs(row.facts.signed_amount_cents ?? 0)) }]); setChecked(false) }}><option value="transfer">Transfer / card payment between accounts</option><option value="purchase_funding">One purchase with bank / wallet funding</option><option value="refund">Refund allocated to an original purchase</option></select></label>
    <p>{kind === 'purchase_funding' ? 'Select the purchase and its actual negative bank funding rows. The local movement plus funding allocations must equal the complete purchase. Missing funding stays unresolved.' : kind === 'transfer' ? 'Select opposing movements on distinct accounts with equal total allocations.' : 'Select one original purchase and one refund, with equal allocated amounts.'}</p>
    {members.map((member, index) => <article className="source-link-member" key={member.row.id}><RowFacts row={member.row} /><ReviewedSourcePreview row={member.row} disabled={disabled} /><label>Role for selected row {index + 1}<select value={member.role} onChange={(event) => { setMembers(members.map((item, position) => position === index ? { ...item, role: event.target.value as Member['role'] } : item)); setChecked(false) }}>{roles.map((role) => <option key={role} value={role}>{role.replaceAll('_', ' ')}</option>)}</select></label><label>Allocation for selected row {index + 1}<input inputMode="decimal" value={member.amount} onChange={(event) => { setMembers(members.map((item, position) => position === index ? { ...item, amount: event.target.value } : item)); setChecked(false) }} /></label><button type="button" onClick={() => { setMembers(members.filter((item) => item.row.id !== member.row.id)); setChecked(false) }}>Remove selected row {index + 1}</button></article>)}
    <details><summary>Choose another approved physical row</summary>{loading ? <p role="status">Loading related rows…</p> : candidates.length === 0 ? <p>No approved rows on this page. Approve the related source facts first.</p> : candidates.map((candidate) => <label className="source-review-check" key={candidate.id}><input type="checkbox" checked={members.some((member) => member.row.id === candidate.id)} disabled={!members.some((member) => member.row.id === candidate.id) && members.length >= 12} onChange={(event) => { setMembers(event.target.checked ? [...members, { row: candidate, role: kind === 'purchase_funding' ? 'funding' : kind === 'refund' ? 'refund' : 'movement', amount: statementDollars(Math.abs(candidate.facts.signed_amount_cents ?? 0)) }] : members.filter((member) => member.row.id !== candidate.id)); setChecked(false) }} /><RowFacts row={candidate} /></label>)}<div className="source-review-pagination"><button type="button" disabled={loading || !history.length} onClick={() => { setLoading(true); setCursor(history.at(-1)!); setHistory(history.slice(0,-1)) }}>Previous related rows</button><button type="button" disabled={loading || next === null} onClick={() => { setLoading(true); setHistory([...history,cursor]); setCursor(next) }}>Next related rows</button></div></details>
    <label>Link review note<input value={reason} maxLength={500} required onChange={(event) => setReason(event.target.value)} /></label><label className="source-review-check"><input type="checkbox" checked={checked} onChange={(event) => setChecked(event.target.checked)} />I checked every selected source, account, role and allocation. Approve this exact link.</label><button type="submit" disabled={!checked || !reason.trim() || members.length < 2}>Approve reviewed link</button>{error && <div role="alert"><p>{error}</p><button type="button" onClick={() => { setLoading(true); setAttempt((value) => value + 1) }}>Retry related rows</button></div>}
  </fieldset></form>
}
function ProjectionForm({ row, groups, mutate, disabled }: { row: ReviewedRow; groups: ReviewedEconomicGroup[]; mutate: Mutation; disabled: boolean }) {
  const [checked, setChecked] = useState(false); const [reason, setReason] = useState('')
  const expense = row.facts.disposition === 'include' && ['purchase','fee','interest'].includes(row.facts.event_type) && (row.facts.signed_amount_cents ?? 0) < 0
  const fundingRequired = expense && row.facts.purchase_amount_cents !== Math.abs(row.facts.signed_amount_cents ?? 0)
  const fundingReady = !fundingRequired || groups.some((group) => group.approved?.kind === 'purchase_funding' && group.approved.current && group.approved.members.some((member) => member.role === 'purchase' && member.record.id === row.id))
  if (!expense && !row.actual) return null
  const action = row.actual ? expense ? 'replace' : 'void' : 'create'
  return <details><summary>Review spending effect separately</summary><p>{row.actual ? `Existing spending: ${sourceMoney(row.actual.amount_cents)}.` : 'No spending is recorded for this row.'} {expense ? `After approval: ${sourceMoney(row.facts.purchase_amount_cents)} spending on ${row.facts.posted_on}.` : 'After approval: the previous spending entry is removed.'}</p>{!fundingReady && <p>Link the full purchase to its reviewed funding legs first. Spending remains unchanged.</p>}{expense && !row.facts.budget_category_id && <p>Approve a source correction with an active spending category first.</p>}<fieldset disabled={disabled || row.current === false || row.recognized_account?.current === false}><legend>Explicit spending decision</legend><label>Spending review note<input required maxLength={500} value={reason} onChange={(event) => setReason(event.target.value)} /></label><label className="source-review-check"><input type="checkbox" checked={checked} onChange={(event) => setChecked(event.target.checked)} />I approve this exact spending effect. This does not record savings.</label><button type="button" disabled={!checked || !reason.trim() || !fundingReady || expense && !row.facts.budget_category_id} onClick={() => { void mutate('project', { version_id: row.id, expected_version_digest: row.digest, projection: { action, ...(row.actual ? { transaction_id: row.actual.id, expected_digest: row.actual.digest } : {}) }, reason }) }}>Approve spending {action === 'void' ? 'removal' : action === 'replace' ? 'replacement' : 'creation'}</button></fieldset></details>
}
