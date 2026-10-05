import { ReviewedSourcePreview } from './ReviewedSourcePreview'
import { StatementEconomicReview } from './StatementEconomicReview'
import { useEffect, useState, type FormEvent } from 'react'
import { fetchTrackedSourceAccounts, fetchSourceDuplicateCandidates } from '../api'
import { sourceAccountLabel, sourceBasisLabel, sourceDispositionLabel, sourceMoney, sourceLocator, sourceOverlapLabel, sourceTypeLabel, type SourceAccount, type SourceEvent } from '../lib/sourceReview'
import { statementCents, statementDollars, type AccountStatementFacts, type ParticipantSourceReview, type ReviewedRow, type ReviewedSourceAccount, type SourceReviewAction, type TrackedSourceAccount } from '../lib/participantSourceReview'

type Mutation = (action: SourceReviewAction, input: object) => Promise<unknown>

export function StatementAccountReview({ context, accounts, mutate, disabled }: { context: ParticipantSourceReview; accounts: SourceAccount[]; mutate: Mutation; disabled: boolean }) {
  const [selected, setSelected] = useState<number | null>(null)
  return <section className="source-participant-accounts" aria-label="Review statement accounts">
    <h6>1. Check the account and statement period</h6>
    <p>Link each month to the same account you recognize. Blank amounts mean unknown. Checking a balance does not record savings.</p>
    {context.accounts.map((review) => {
      const account = accounts.find((row) => row.id === review.source_account_id)
      if (!account) return null
      return <article className="source-reviewed-account" key={account.id}>
        <strong>{sourceAccountLabel(account, account.id)}</strong>
        <p>{review.approved ? `Reviewed as ${review.approved.tracked_account.label}` : 'Account identity not reviewed yet'}</p>
        <button type="button" disabled={disabled} onClick={() => setSelected(selected === account.id ? null : account.id)}>{selected === account.id ? 'Close account review' : review.approved ? 'Correct account details' : 'Review account details'}</button>
        {selected === account.id && <AccountForm key={`${account.id}:${review.head.lock_version}`} account={account} review={review} mutate={mutate} disabled={disabled} />}
      </article>
    })}
  </section>
}
function AccountForm({ account, review, mutate, disabled }: { account: SourceAccount; review: ReviewedSourceAccount; mutate: Mutation; disabled: boolean }) {
  const initial = review.approved?.statement_facts ?? account
  const [label, setLabel] = useState(review.approved?.tracked_account.label ?? sourceAccountLabel(account, account.id))
  const [basis, setBasis] = useState(review.approved?.tracked_account.account_basis ?? (account.account_basis === 'unknown' ? '' : account.account_basis))
  const [tracked, setTracked] = useState(review.approved?.tracked_account.id.toString() ?? '')
  const [choices, setChoices] = useState<TrackedSourceAccount[]>(review.approved ? [review.approved.tracked_account] : [])
  const [cursor, setCursor] = useState<number | null>(null)
  const [attempt, setAttempt] = useState(0)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [fields, setFields] = useState<Record<string, string>>({ period_start_on: initial.period_start_on ?? '', period_end_on: initial.period_end_on ?? '',
    opening_balance_cents: statementDollars(initial.opening_balance_cents), closing_balance_cents: statementDollars(initial.closing_balance_cents),
    printed_debit_cents: statementDollars(initial.printed_debit_cents), printed_credit_cents: statementDollars(initial.printed_credit_cents), printed_row_count: initial.printed_row_count?.toString() ?? '' })
  const [rowBasis, setRowBasis] = useState<'posted' | 'all'>('printed_row_count_basis' in initial && initial.printed_row_count_basis === 'all' ? 'all' : 'posted')
  const [reason, setReason] = useState('')
  const [checked, setChecked] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [nextCursor, setNextCursor] = useState<number | null>(null)
  useEffect(() => {
    const controller = new AbortController(); let live = true
    fetchTrackedSourceAccounts(cursor, controller.signal).then((page) => {
      if (!live) return
      setChoices((previous) => [...previous.filter((row) => !page.records.some((item) => item.id === row.id)), ...page.records]); setLoading(false)
      setNextCursor(page.next_cursor); setLoadError(null)
    }).catch((failure: unknown) => { if (live) { setLoading(false); setLoadError(failure instanceof Error ? failure.message : 'Could not load account choices.') } })
    return () => { live = false; controller.abort() }
  }, [cursor, attempt])
  async function submit(event: FormEvent) {
    event.preventDefault(); setError(null)
    try {
      const facts: AccountStatementFacts = { period_start_on: fields.period_start_on || null, period_end_on: fields.period_end_on || null,
        opening_balance_cents: statementCents(fields.opening_balance_cents), closing_balance_cents: statementCents(fields.closing_balance_cents),
        printed_debit_cents: statementCents(fields.printed_debit_cents), printed_credit_cents: statementCents(fields.printed_credit_cents),
        printed_row_count: fields.printed_row_count ? Number(fields.printed_row_count) : null, printed_row_count_basis: rowBasis }
      if (facts.printed_row_count !== null && (!/^\d+$/.test(fields.printed_row_count) || !Number.isSafeInteger(facts.printed_row_count))) throw new Error('Use a whole row count or leave it unknown.')
      await mutate('account_link', { source_account_id: account.id, base_version_id: review.head.approved_version_id, base_lock_version: review.head.lock_version,
        tracked_account_id: tracked ? Number(tracked) : null, label, account_basis: basis, statement_facts: facts, reason })
    } catch (failure) { setError(failure instanceof Error ? failure.message : 'Check account details.') }
  }
  return <form className="source-review-form" onSubmit={(event) => { void submit(event) }}>
    <fieldset disabled={disabled}><legend>Account details from your statement</legend>
      <label>Recognized account<select value={tracked} onChange={(event) => { setTracked(event.target.value); setChecked(false) }}><option value="">Create a separate account</option>{choices.map((row) => <option value={row.id} key={row.id}>{row.label} · {row.account_basis === 'asset' ? 'bank / wallet' : 'card / debt'}</option>)}</select></label>
      {loading && <p role="status">Loading account choices…</p>}{loadError && <div role="alert"><p>{loadError}</p><button type="button" onClick={() => { setLoading(true); setAttempt((value) => value + 1) }}>Retry account choices</button></div>}
      {nextCursor && <button type="button" disabled={loading} onClick={() => { setLoading(true); setCursor(nextCursor) }}>More account choices</button>}
      {!tracked && <><label>Account label<input value={label} maxLength={120} required onChange={(event) => { setLabel(event.target.value); setChecked(false) }} /></label><label>Account type<select required value={basis} onChange={(event) => { setBasis(event.target.value); setChecked(false) }}><option value="">Choose account type</option><option value="asset">Bank or wallet balance</option><option value="liability">Credit card or debt owed</option></select></label></>}
      <div className="source-review-field-grid">{Object.entries(fields).map(([key, value]) => <label key={key}>{({ period_start_on: 'Period starts', period_end_on: 'Period ends', opening_balance_cents: 'Opening balance', closing_balance_cents: 'Closing balance', printed_debit_cents: 'Printed debits / charges', printed_credit_cents: 'Printed credits / payments', printed_row_count: 'Printed row count' } as Record<string, string>)[key]}<input type={key.includes('_on') ? 'date' : 'text'} inputMode={key.includes('_on') ? undefined : 'decimal'} value={value} onChange={(event) => { setFields({ ...fields, [key]: event.target.value }); setChecked(false) }} /></label>)}</div>
      <label>Printed count includes<select value={rowBasis} onChange={(event) => { setRowBasis(event.target.value as 'posted' | 'all'); setChecked(false) }}><option value="posted">Financial movements only</option><option value="all">All printed rows</option></select></label>
      <label>Review note<input required maxLength={500} value={reason} onChange={(event) => setReason(event.target.value)} placeholder="What you checked or corrected" /></label>
      <label className="source-review-check"><input type="checkbox" checked={checked} onChange={(event) => setChecked(event.target.checked)} />I checked the account, period and the known amounts against my statement.</label>
      {(!checked || !reason.trim()) && <p className="source-review-help">Add a short review note and check the confirmation to approve these account details.</p>}
      <button type="submit" disabled={!checked || !reason.trim() || loading || Boolean(loadError)}>Approve these account details</button>
    </fieldset>{error && <p role="alert">{error}</p>}
  </form>
}

export function StatementRowEditor({ importId, context, event, mutate, disabled }: { importId: number; context: ParticipantSourceReview; event: SourceEvent; mutate: Mutation; disabled: boolean }) {
  const row = context.rows[event.id]
  const identity = context.accounts.find((account) => account.source_account_id === event.financial_source_account_id)?.approved
  if (!row || !identity) return <p>Review this row’s account details first. No financial values have been approved from this row.</p>
  return <RowForm key={`${event.id}:${row.head.lock_version}:${row.pending?.digest ?? ''}`} importId={importId} context={context} event={event} mutate={mutate} disabled={disabled} identityId={identity.id} />
}
function RowForm({ importId, context, event, mutate, disabled, identityId }: { importId: number; context: ParticipantSourceReview; event: SourceEvent; mutate: Mutation; disabled: boolean; identityId: number }) {
  const row = context.rows[event.id]
  const current = row.pending?.facts ?? row.approved?.facts
  const [disposition, setDisposition] = useState(current?.disposition ?? (event.row_kind === 'informational' ? 'informational' : 'include'))
  const [type, setType] = useState(current?.event_type ?? event.event_type)
  const [amount, setAmount] = useState(statementDollars(current ? current.signed_amount_cents : event.signed_amount_cents))
  const [purchase, setPurchase] = useState(statementDollars(current ? current.purchase_amount_cents : event.expense_amount_cents))
  const [date, setDate] = useState(current?.posted_on ?? event.posted_on ?? '')
  const [merchant, setMerchant] = useState(current?.merchant ?? event.evidence?.merchant ?? '')
  const [category, setCategory] = useState(current?.budget_category_id?.toString() ?? '')
  const [overlap, setOverlap] = useState(current?.overlap_disposition ?? 'new')
  const [matched, setMatched] = useState(current?.matched_version_id?.toString() ?? '')
  const [reason, setReason] = useState(row.pending?.reason ?? '')
  const [addExpense, setAddExpense] = useState(Boolean(row.pending && row.pending.projection.action !== 'none'))
  const [authorized, setAuthorized] = useState(current?.authorized_on ?? event.authorized_on ?? '')
  const [reference, setReference] = useState(current?.external_reference ?? '')
  const [checked, setChecked] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const purchaseFacts = ['include', 'match'].includes(disposition) && ['purchase', 'fee', 'interest'].includes(type) && amount.trim().startsWith('-')
  const expense = disposition === 'include' && purchaseFacts
  const splitFunding = purchaseFacts && (() => { try { return statementCents(purchase) !== Math.abs(statementCents(amount) ?? 0) } catch { return true } })()
  async function stage(eventObject: FormEvent) {
    eventObject.preventDefault(); setError(null)
    try {
      await mutate('stage', { event_id: event.id, base_version_id: row.head.approved_version_id, base_lock_version: row.head.lock_version,
        expected_pending_draft: row.pending ? { id: row.pending.id, digest: row.pending.digest, lock_version: row.pending.lock_version } : null,
        reason, projection: addExpense && expense && !splitFunding ? row.approved?.actual ? { action: 'replace', transaction_id: row.approved.actual.id, expected_digest: row.approved.actual.digest } : { action: 'create' } : addExpense && row.approved?.actual ? { action: 'void', transaction_id: row.approved.actual.id, expected_digest: row.approved.actual.digest } : { action: 'none' },
        facts: { source_account_identity_version_id: identityId, disposition, event_type: type,
          signed_amount_cents: disposition === 'informational' ? null : statementCents(amount), purchase_amount_cents: purchaseFacts ? statementCents(purchase, false) : null,
          posted_on: date || null, authorized_on: authorized || null, external_reference: reference || null, merchant: merchant || null, budget_category_id: category ? Number(category) : null,
          overlap_disposition: disposition === 'match' ? 'match' : ['exclude', 'informational'].includes(disposition) ? 'excluded' : overlap,
          matched_version_id: disposition === 'match' ? Number(matched) : null } })
    } catch (failure) { setError(failure instanceof Error ? failure.message : 'Check the reviewed row.') }
  }
  return <section aria-label="Participant row review">
    <p>{row.approved ? `Approved version ${row.approved.version_number} remains in use until you approve a correction.` : 'No approved version yet.'}</p>
    {row.pending && <div className="source-pending-proposal">
      <h6>Review the saved proposal</h6><p>{sourceDispositionLabel(row.pending.facts.disposition)} · {sourceTypeLabel(row.pending.facts.event_type)} · {sourceMoney(row.pending.facts.signed_amount_cents, true)} · {row.pending.facts.posted_on ?? 'Date unknown'}</p>
      <p>{row.pending.facts.merchant ?? 'No merchant'} · Complete purchase {sourceMoney(row.pending.facts.purchase_amount_cents)} · {context.categories.find((item) => item.id === row.pending?.facts.budget_category_id)?.name ?? 'Explicitly uncategorized'}</p>
      <p>Recognized account: {context.accounts.find((account) => account.approved?.id === row.pending!.facts.source_account_identity_version_id)?.approved?.tracked_account.label ?? 'Account identity unavailable'} · {sourceBasisLabel(context.accounts.find((account) => account.approved?.id === row.pending!.facts.source_account_identity_version_id)?.approved?.tracked_account.account_basis)}</p><p>Duplicate check: {sourceOverlapLabel(row.pending.facts.overlap_disposition)}. {row.pending.facts.matched_version_id ? 'Compare the matched approved copy below.' : 'No matched duplicate.'}</p><p>Authorized: {row.pending.facts.authorized_on ?? 'Unknown'} · Reference: {row.pending.facts.external_reference ?? 'None'}</p><p>{row.pending.reason}</p><p>Spending effect: {row.pending.projection.action === 'none' ? `unchanged${row.approved?.actual ? ` at ${sourceMoney(row.approved.actual.amount_cents)}` : '; no new spending'}` : row.pending.projection.action === 'void' ? `remove ${sourceMoney(row.approved?.actual?.amount_cents)} existing spending` : `${row.pending.projection.action === 'replace' ? `replace ${sourceMoney(row.approved?.actual?.amount_cents)} with` : 'create'} ${sourceMoney(row.pending.facts.purchase_amount_cents)} spending`}.</p>
      {row.pending.matched_target && <ReviewedSourcePreview row={row.pending.matched_target} disabled={disabled} />}
      {row.pending.matched_target && <p>Matched approved copy: {row.pending.matched_target.facts.merchant ?? 'Reviewed movement'} · {sourceMoney(row.pending.matched_target.facts.signed_amount_cents, true)} · complete purchase {sourceMoney(row.pending.matched_target.facts.purchase_amount_cents)} · {row.pending.matched_target.facts.posted_on} · {row.pending.matched_target.recognized_account?.label ?? 'Account unavailable'} · {reviewedSourceLabel(row.pending.matched_target)} · {row.pending.matched_target.current === false ? 'Target changed; refresh and prepare a new match' : `Approved version ${row.pending.matched_target.version_number}`}</p>}
      {row.pending.facts.disposition === 'match' && !row.pending.matched_target && <p>Details of the matched approved copy are unavailable. Refresh before approving this match.</p>}
      <details className="source-review-technical"><summary>Review record details</summary><p>Account identity ID: {row.pending.facts.source_account_identity_version_id} · Saved proposal ID: {row.pending.id} · Matched approved row ID: {row.pending.facts.matched_version_id ?? 'None'}.</p></details>
      <label className="source-review-check"><input type="checkbox" disabled={disabled} checked={checked} onChange={(e) => setChecked(e.target.checked)} />I reviewed this saved proposal and approve these facts.</label>
      <button type="button" className="source-review-primary" disabled={disabled || !checked || row.pending.facts.disposition === 'match' && (!row.pending.matched_target || row.pending.matched_target.current === false) || row.pending.recognized_account?.current === false} onClick={() => { void mutate('approve', { draft_id: row.pending!.id, draft_digest: row.pending!.digest, draft_lock_version: row.pending!.lock_version }) }}>Approve saved row proposal</button>
      <button type="button" disabled={disabled} onClick={() => { void mutate('cancel', { draft_id: row.pending!.id, draft_digest: row.pending!.digest, draft_lock_version: row.pending!.lock_version }) }}>Discard pending proposal</button>
    </div>}
    <form className="source-review-form" onSubmit={(e) => { void stage(e) }}><fieldset disabled={disabled}><legend>{row.pending ? 'Replace the pending proposal' : 'Prepare a row proposal'}</legend>
      <label>How to use this row<select value={disposition} onChange={(e) => { setDisposition(e.target.value as typeof disposition); setAddExpense(false) }}><option value="include">Include this financial movement</option><option value="match">Match an approved duplicate</option><option value="exclude">Exclude with a review note</option><option value="informational">Information only, no movement</option></select></label>
      <label>Transaction type<select value={type} onChange={(e) => { setType(e.target.value as typeof type); setAddExpense(false) }}>{['unknown', 'purchase', 'fee', 'refund', 'income', 'transfer', 'debt_payment', 'cash_withdrawal', 'interest', 'adjustment'].map((value) => <option value={value} key={value}>{sourceTypeLabel(value as SourceEvent['event_type'])}</option>)}</select></label>
      <div className="source-review-field-grid"><label>Signed movement<input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="Negative outflow, positive inflow" /></label><label>Posted date<input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></label>{purchaseFacts && <label>Complete purchase amount<input required inputMode="decimal" value={purchase} onChange={(e) => setPurchase(e.target.value)} /></label>}</div>
      <label>Authorized date (optional)<input type="date" value={authorized} onChange={(e) => setAuthorized(e.target.value)} /></label><label>Statement reference (optional)<input value={reference} maxLength={160} onChange={(e) => setReference(e.target.value)} /></label>
      <label>Merchant / description<input value={merchant} maxLength={120} onChange={(e) => setMerchant(e.target.value)} /></label>
      {purchaseFacts && <label>Spending category<select value={category} onChange={(e) => setCategory(e.target.value)}><option value="">Explicitly uncategorized</option>{context.categories.map((item) => <option value={item.id} key={item.id}>{item.name}</option>)}</select></label>}
      {disposition === 'include' && <label>Overlap decision<select value={overlap} onChange={(e) => setOverlap(e.target.value as typeof overlap)}><option value="new">No known overlap</option><option value="distinct">I checked: a separate genuine movement</option><option value="canonical">Use this statement row as the main copy</option></select></label>}
      {disposition === 'match' && <DuplicateChoices key={`${amount}:${date}`} importId={importId} eventId={event.id} amount={amount} date={date} selected={matched} disabled={disabled} choose={(candidate) => { setMatched(String(candidate.id)); setType(candidate.facts.event_type); setAmount(statementDollars(candidate.facts.signed_amount_cents)); setDate(candidate.facts.posted_on ?? ''); setMerchant(candidate.facts.merchant ?? ''); setPurchase(statementDollars(candidate.facts.purchase_amount_cents)); setCategory(candidate.facts.budget_category_id?.toString() ?? '') }} />}
      <label>Review note<input required maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="What you checked or corrected" /></label>
      {splitFunding && <p>Approve the source facts first, then link the reviewed funding legs below before adding the complete purchase to spending.</p>}
      {row.approved?.actual && !addExpense && <p>Existing spending of {sourceMoney(row.approved.actual.amount_cents)} stays unchanged with a source-only correction.</p>}
      {(!splitFunding && expense || row.approved?.actual && !splitFunding) && <label className="source-review-check"><input type="checkbox" checked={addExpense} onChange={(e) => setAddExpense(e.target.checked)} />{row.approved?.actual ? expense ? 'Replace the previous spending entry with this correction' : 'Remove the previous spending entry when this correction is approved' : 'Also add this approved purchase to my spending'}</label>}
      <button type="submit" disabled={!reason.trim()}>Save proposal for review</button>
    </fieldset>{error && <p role="alert">{error}</p>}</form>
    {row.approved && (row.approved.facts.disposition === 'include' || row.approved.actual) && <StatementEconomicReview importId={importId} eventId={event.id} row={row.approved} context={context} mutate={mutate} disabled={disabled} />}
  </section>
}

export function StatementCoverageReview({ context, mutate, disabled }: { context: ParticipantSourceReview; mutate: Mutation; disabled: boolean }) {
  const [checked, setChecked] = useState(false)
  const [reason, setReason] = useState('')
  const [status, setStatus] = useState<'complete' | 'qualified'>('qualified')
  return <details className="source-coverage-details"><summary>3. Approve statement coverage and limitations</summary>
    <p>{context.coverage.approved_rows} / {context.coverage.represented_rows} rows approved · {context.coverage.pending_corrections} pending corrections.</p>
    {context.approved_coverage && <p>{context.approved_coverage.current ? 'Current' : 'Outdated'} coverage approval: {context.approved_coverage.status}.</p>}
    <p>{context.coverage.deficiencies.length ? `Limitations: ${context.coverage.deficiencies.map((item) => item.replaceAll('_', ' ')).join('; ')}` : 'All recorded coverage checks passed. Confirm the source against your statement before approval.'}</p>
    <fieldset disabled={disabled}><legend>My statement review</legend><label>Coverage decision<select value={status} onChange={(e) => { setStatus(e.target.value as typeof status); setChecked(false) }}><option value="qualified">Use reviewed facts with these limitations</option><option value="complete" disabled={context.coverage.deficiencies.length > 0}>Complete statement coverage</option></select></label>
      <label>Review note<input required maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} /></label>
      <label className="source-review-check"><input type="checkbox" checked={checked} onChange={(e) => setChecked(e.target.checked)} />I checked the declared account periods and row coverage. Any unresolved rows or limitations remain visible.</label>
      <button type="button" className="source-review-primary" disabled={!checked || !reason.trim()} onClick={() => { void mutate('coverage', { revision_id: context.coverage.revision_id, expected_digest: context.coverage.content_digest, requested_status: status, reason,
        coverage_attestation: { all_document_rows_accounted: checked, accounts: context.accounts.filter((account) => account.approved).map((account) => ({ source_account_id: account.source_account_id, identity_version_id: account.approved!.id,
          period_start_on: account.approved!.statement_facts.period_start_on, period_end_on: account.approved!.statement_facts.period_end_on, all_rows_accounted: checked })) } }) }}>Approve declared coverage</button>
    </fieldset>
  </details>
}

function DuplicateChoices({ importId, eventId, amount, date, selected, disabled, choose }: { importId: number; eventId: number; amount: string; date: string; selected: string; disabled: boolean; choose: (row: ReviewedRow) => void }) {
  const [rows, setRows] = useState<ReviewedRow[]>([])
  const [cursor, setCursor] = useState<number | null>(null)
  const [attempt, setAttempt] = useState(0)
  const [next, setNext] = useState<number | null>(null)
  const [history, setHistory] = useState<Array<number | null>>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  useEffect(() => {
    const controller = new AbortController(); let live = true
    Promise.resolve().then(() => fetchSourceDuplicateCandidates(importId, eventId, cursor, controller.signal, { signed_amount_cents: statementCents(amount) ?? undefined, posted_on: date || undefined })).then((page) => { if (live) { setRows(page.records); setError(null); setNext(page.next_cursor); setLoading(false) } }).catch((failure: unknown) => { if (live) { setError(failure instanceof Error ? failure.message : 'Could not load reviewed duplicates.'); setLoading(false) } })
    return () => { live = false; controller.abort() }
  }, [importId, eventId, cursor, attempt, amount, date])
  return <fieldset disabled={disabled}><legend>Choose an approved duplicate to compare</legend><p>Date and amount alone do not prove a duplicate. Check the source and your account before choosing.</p>
    {rows.map((row) => <div key={row.id}><label className="source-review-check"><input type="radio" name={`duplicate-${eventId}`} checked={selected === String(row.id)} onChange={() => choose(row)} />{row.facts.merchant ?? 'Reviewed movement'} · {row.facts.posted_on} · {sourceMoney(row.facts.signed_amount_cents, true)} · {row.facts.event_type.replaceAll('_', ' ')} · approved version {row.version_number} · {row.recognized_account?.label ?? 'Reviewed account'} · {reviewedSourceLabel(row)}</label><ReviewedSourcePreview row={row} disabled={disabled} /></div>)}
    {loading ? <p role="status">Loading comparable approved rows…</p> : !rows.length && <p>No approved movement with the same account, original date and signed amount. Review the main copy first.</p>}
    {error && <div role="alert"><p>{error}</p><button type="button" onClick={() => { setLoading(true); setAttempt((value) => value + 1) }}>Retry reviewed candidates</button></div>}<button type="button" disabled={loading || !history.length} onClick={() => { setLoading(true); setCursor(history.at(-1)!); setHistory(history.slice(0,-1)) }}>Previous reviewed candidates</button>{next && <button type="button" disabled={loading} onClick={() => { setLoading(true); setHistory([...history, cursor]); setCursor(next) }}>More reviewed candidates</button>}
  </fieldset>
}

function reviewedSourceLabel(row: ReviewedRow): string { return row.source ? `${row.source.filename ?? 'Retained source'} · ${sourceLocator({ locator: row.source.locator } as SourceEvent)}${row.source.source_available ? '' : ' · original unavailable'}` : 'Source location unavailable' }
