import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { ApiRequestError } from '../api'
import { optionalDebtApi } from '../optionalDebtApi'
import type { BaselineScope } from '../lib/financialBaseline'
import { assertDebtScope, checkedHouseholdDebtCandidate, type HouseholdDebtCandidate, checkedDebtCandidate, checkedDebtRecord, checkedDebtSummary, checkedDebtTerms, debtApproval, debtApr, debtMapping, debtMoney, type DebtCandidate, type DebtCard, type DebtDraft, type DebtEnvelope, type DebtInput, type DebtMutation, type DebtPage, type DebtScope, type DebtSummary, type DebtTerms, type DebtVersion, type OptionalDebtApi } from '../lib/optionalDebt'
import { useOptionalDebtMutation } from '../lib/useOptionalDebtMutation'
import { usePilotDialog } from '../lib/usePilotDialog'
import { OptionalDebtTerms } from './OptionalDebtTerms'
import './OptionalDebtReview.css'
export type OptionalDebtReviewProps = { actorScope: BaselineScope; cohortId: number; onClose: () => void; api?: OptionalDebtApi }
type Pages = { cards: DebtPage<DebtCard>; drafts: DebtPage<DebtDraft>; versions: DebtPage<DebtVersion>; candidates: DebtPage<DebtCandidate>; household: DebtPage<HouseholdDebtCandidate> }
type Kind = keyof Pages
const failureMessage = (failure: unknown) => failure instanceof Error ? failure.message : 'Card review could not be checked. Try again.'
function TermsView({ terms }: { terms: DebtTerms }) {
  return <div className="debt-term-summary"><dl><div><dt>Balance</dt><dd>{debtMoney(terms.balance_cents)}</dd></div><div><dt>Required minimum</dt><dd>{debtMoney(terms.minimum_payment_cents)}</dd></div><div><dt>APR</dt><dd>{debtApr(terms.apr_bps)}</dd></div><div><dt>Terms as of</dt><dd>{terms.as_of_on}</dd></div><div><dt>Due date</dt><dd>{terms.due_on ?? 'Unknown'}</dd></div><div><dt>Status</dt><dd>{terms.status.replace('_', ' ')}</dd></div></dl>
    {(terms.promotional_apr_bps !== null || terms.promotional_expires_on !== null || terms.post_promo_apr_bps !== null) && <p>Promotional APR {debtApr(terms.promotional_apr_bps)} · Expires {terms.promotional_expires_on ?? 'Unknown'} · APR after promotion {debtApr(terms.post_promo_apr_bps)}</p>}
    {terms.rate_segments.length > 0 && <ul>{terms.rate_segments.map((row, index) => <li key={index}>{row.label}: balance {debtMoney(row.balance_cents)}, APR {debtApr(row.apr_bps)}, expiry {row.promotional_expires_on ?? 'Unknown'}, successor APR {debtApr(row.post_promo_apr_bps)}</li>)}</ul>}
  </div>
}
function HouseholdSnapshot({ snapshot }: { snapshot: Record<string, unknown> }) {
  const money = (value: unknown, known: unknown) => known === true && typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : null
  const rawApr = snapshot.interest_rate_percent
  const apr = (typeof rawApr === 'number' || typeof rawApr === 'string' && rawApr.trim() !== '') && Number.isFinite(Number(rawApr)) && Number(rawApr) >= 0 && Number(rawApr) <= 999.99 ? Math.round(Number(rawApr) * 100) : null
  return <details><summary>Saved household values retained with this link</summary><p>Balance {debtMoney(money(snapshot.balance_cents, snapshot.balance_known))} · Required minimum {debtMoney(money(snapshot.minimum_payment_cents, snapshot.minimum_payment_known))} · APR {debtApr(apr)}</p><p>The optional terms above keep their own reviewed date and values. This snapshot does not synchronize either view.</p></details>
}
function checkedPage<T>(value: DebtPage<T>, scope: DebtScope) {
  assertDebtScope(value, scope)
  if (!Array.isArray(value.records) || value.next_cursor !== null && (!Number.isSafeInteger(value.next_cursor) || value.next_cursor < 1)) throw new Error('Private card pagination is incomplete. Refresh before continuing.')
  return value
}
export function OptionalDebtReview(props: OptionalDebtReviewProps) { return <DebtReviewBody key={`${props.actorScope.user_id}:${props.actorScope.household_id}:${props.cohortId}`} {...props}/> }
function DebtReviewBody({ actorScope, cohortId, onClose, api = optionalDebtApi }: OptionalDebtReviewProps) {
  const dialog = usePilotDialog(onClose), reviewHeading = useRef<HTMLHeadingElement>(null), alive = useRef(true), generation = useRef(0), findControllers = useRef(new Set<AbortController>()), enrollmentIdentity = useRef<number | null>(null)
  const bumpGeneration = useCallback(() => { generation.current++ }, [])
  const actor = useMemo(() => ({ user_id: actorScope.user_id, household_id: actorScope.household_id }), [actorScope.user_id, actorScope.household_id])
  const [enrollmentId, setEnrollmentId] = useState<number>(), [data, setData] = useState<{ summary: DebtSummary; pages: Pages } | null>(null), [loading, setLoading] = useState(true), [denied, setDenied] = useState(false), [error, setError] = useState<string | null>(null), [notice, setNotice] = useState<string | null>(null), [attempt, setAttempt] = useState(0)
  const [cursors, setCursors] = useState<Record<Kind, number | null>>({ cards: null, drafts: null, versions: null, candidates: null, household: null }), [previous, setPrevious] = useState<Record<Kind, (number | null)[]>>({ cards: [], drafts: [], versions: [], candidates: [], household: [] })
  const [editor, setEditor] = useState<{ card?: DebtCard; useHousehold?: boolean } | null>(null), [proposal, setProposal] = useState<DebtInput | null>(null), [draftReview, setDraftReview] = useState<{ draft: DebtDraft; card: DebtCard } | null>(null), [accepted, setAccepted] = useState(false), [freshAccepted, setFreshAccepted] = useState(false), [tab, setTab] = useState<Kind>('cards')
  const scope = useMemo(() => enrollmentId && !denied ? { ...actor, cohort_id: cohortId, enrollment_id: enrollmentId } : undefined, [actor, cohortId, enrollmentId, denied])
  const clearForms = useCallback(() => { setEditor(null); setProposal(null); setDraftReview(null); setAccepted(false); setFreshAccepted(false) }, [])
  const revoke = useCallback(() => { generation.current++; findControllers.current.forEach(controller => controller.abort()); setDenied(true); setData(null); clearForms() }, [clearForms])
  const refresh = useCallback(() => { generation.current++; findControllers.current.forEach(controller => controller.abort()); setData(null); setLoading(true); clearForms(); setAttempt(value => value + 1) }, [clearForms])
  const done = useCallback((result: DebtMutation) => { setNotice('base_version_id' in result.record ? 'Pending proposal saved. Review it separately before approving.' : 'Card terms approved. Your savings are unchanged.'); setTab('base_version_id' in result.record ? 'drafts' : 'cards'); refresh() }, [refresh])
  const conflict = useCallback(() => { clearForms(); setData(null); setLoading(true); setAttempt(value => value + 1) }, [clearForms])
  const mutation = useOptionalDebtMutation(scope, api, done, revoke, conflict)
  const busy = loading || denied || Boolean(mutation.pending && !mutation.pending.fresh)
  useEffect(() => {
    alive.current = true
    const owned = findControllers.current
    return () => { alive.current = false; bumpGeneration(); owned.forEach(controller => controller.abort()); owned.clear() }
  }, [actor, cohortId, bumpGeneration])
  useEffect(() => {
    let live = true; const controller = new AbortController()
    api.summary(cohortId, controller.signal).then(async raw => {
      const summary = checkedDebtSummary(raw, actor, cohortId), expected = { ...actor, cohort_id: cohortId, enrollment_id: summary.enrollment_id }
      const [cards, drafts, versions, candidates, household] = await Promise.all([api.records<DebtCard>(expected, 'cards', cursors.cards, controller.signal), api.records<DebtDraft>(expected, 'drafts', cursors.drafts, controller.signal), api.records<DebtVersion>(expected, 'versions', cursors.versions, controller.signal), api.candidates(expected, cursors.candidates, controller.signal), api.householdCandidates(expected, cursors.household, controller.signal)])
      if (!live) return
      const pages = { cards: checkedPage(cards, expected), drafts: checkedPage(drafts, expected), versions: checkedPage(versions, expected), candidates: checkedPage(candidates, expected), household: checkedPage(household, expected) }
      for (const record of [...cards.records, ...drafts.records, ...versions.records]) checkedDebtRecord(record, expected)
      candidates.records.forEach(checkedDebtCandidate)
      household.records.forEach(checkedHouseholdDebtCandidate)
      if (enrollmentIdentity.current !== null && enrollmentIdentity.current !== summary.enrollment_id) { bumpGeneration(); findControllers.current.forEach(item => item.abort()); clearForms() }
      enrollmentIdentity.current = summary.enrollment_id
      setEnrollmentId(summary.enrollment_id); setData({ summary, pages }); setLoading(false); setError(null)
    }).catch(failure => { if (!live) return; setLoading(false); setData(null); clearForms(); setError(failureMessage(failure)); if (failure instanceof ApiRequestError && [401, 403, 404].includes(failure.status)) revoke() })
    return () => { live = false; controller.abort() }
  }, [api, actor, cohortId, cursors, attempt, clearForms, revoke, bumpGeneration])
  useEffect(() => { const check = () => { if (!document.hidden && !mutation.pending?.working) refresh() }; window.addEventListener('focus', check); document.addEventListener('visibilitychange', check); return () => { window.removeEventListener('focus', check); document.removeEventListener('visibilitychange', check) } }, [refresh, mutation.pending?.working])
  useEffect(() => {
    const containTab = (event: KeyboardEvent) => {
      if (event.key !== 'Tab' || !dialog.current) return
      const elements = Array.from(dialog.current.querySelectorAll<HTMLElement>('button,input,select,textarea,summary,a[href],[tabindex]:not([tabindex="-1"])')).filter(element => !element.matches(':disabled') && element.getClientRects().length > 0)
      event.preventDefault(); event.stopPropagation()
      if (!elements.length) { dialog.current.focus(); return }
      const index = elements.indexOf(document.activeElement as HTMLElement)
      elements[index < 0 ? event.shiftKey ? elements.length - 1 : 0 : (index + (event.shiftKey ? -1 : 1) + elements.length) % elements.length].focus()
    }
    document.addEventListener('keydown', containTab, true)
    return () => document.removeEventListener('keydown', containTab, true)
  }, [dialog])
  async function find<T extends DebtCard | DebtDraft>(kind: 'cards' | 'drafts', id: number): Promise<T> {
    if (!scope) throw new Error('Reopen your current private card review.')
    const controller = new AbortController(); findControllers.current.add(controller)
    try {
      let cursor: number | null = null
      for (;;) {
        const page: DebtPage<T> = checkedPage(await api.records<T>(scope, kind, cursor, controller.signal), scope)
        const record = page.records.find(row => row.id === id)
        if (record) return checkedDebtRecord(record, scope)
        if (page.next_cursor === null) throw new Error('The original card review was not found. Check its request status again.')
        if (cursor !== null && page.next_cursor <= cursor) throw new Error('Private record pagination did not advance. Try again.')
        cursor = page.next_cursor
      }
    } finally { findControllers.current.delete(controller) }
  }
  async function openDraft(id: number) {
    const epoch = generation.current; setAccepted(false); setError(null)
    try {
      const draft = await find<DebtDraft>('drafts', id), card = await find<DebtCard>('cards', draft.savings_debt_card_id)
      if (!alive.current || epoch !== generation.current) return
      checkedDebtTerms(draft.terms)
      if (draft.status !== 'pending') throw new Error('This proposal is already approved. Check the original request before starting another action.')
      setDraftReview({ draft, card }); setEditor(null); setProposal(null)
      requestAnimationFrame(() => reviewHeading.current?.focus())
    } catch (failure) { if (!alive.current || epoch !== generation.current) return; setError(failureMessage(failure)); if (failure instanceof ApiRequestError && [401, 403, 404].includes(failure.status)) revoke() }
  }
  async function freshReview() {
    if ((!mutation.reviewFresh && !mutation.pending?.fresh) || !freshAccepted) return
    const pending = mutation.pending!; mutation.reviewFresh?.(); clearForms()
    if (pending.action === 'stage') {
      const epoch = generation.current
      try { const card = pending.cardId ? await find<DebtCard>('cards', pending.cardId) : undefined; if (alive.current && epoch === generation.current) setEditor({ card }) }
      catch (failure) { if (alive.current && epoch === generation.current) { setError(failureMessage(failure)); if (failure instanceof ApiRequestError && [401, 403, 404].includes(failure.status)) revoke() } }
    }
    else if (pending.draftId) await openDraft(pending.draftId)
  }
  function page(kind: Kind, next: number | null, backwards = false) { if (busy) return; clearForms(); setData(null); setLoading(true); setPrevious(values => ({ ...values, [kind]: backwards ? values[kind].slice(0, -1) : [...values[kind], cursors[kind]] })); setCursors(values => ({ ...values, [kind]: next })) }
  const navigation = (kind: Kind) => <nav aria-label={`${kind} pages`}><button type="button" className="debt-secondary" disabled={busy || !previous[kind].length} onClick={() => page(kind, previous[kind].at(-1) ?? null, true)}>Previous {kind}</button><span>Page {previous[kind].length + 1}</span><button type="button" className="debt-secondary" disabled={busy || data?.pages[kind].next_cursor == null} onClick={() => page(kind, data!.pages[kind].next_cursor)}>Next {kind}</button></nav>
  function reviewProposal(input: DebtInput) { setProposal(input); setAccepted(false); requestAnimationFrame(() => reviewHeading.current?.focus()) }
  const editingAllowed = (cardId?: number) => !busy && (!mutation.pending || mutation.pending.fresh && mutation.pending.action === 'stage' && (mutation.pending.cardId ?? null) === (cardId ?? null))
  const approvalAllowed = (draftId: number) => !busy && (!mutation.pending || mutation.pending.fresh && mutation.pending.action === 'approve' && mutation.pending.draftId === draftId)
  const labels = new Map(data?.summary.cards.map(row => [row.card_id, row.label]) ?? [])
  const householdDraftChanged = draftReview && data?.pages.household.records.some(row => row.household_debt_id === draftReview.draft.household_debt_id && row.fingerprint !== draftReview.draft.household_debt_fingerprint)
  const canApprove = !householdDraftChanged && draftReview && draftReview.draft.base_version_id === draftReview.card.current_version_id && draftReview.draft.base_head_lock_version === draftReview.card.lock_version
  return <div className="optional-debt-overlay"><section ref={dialog} className="optional-debt-dialog" role="dialog" aria-modal="true" aria-labelledby="optional-debt-title" tabIndex={-1}><header><div><p className="debt-eyebrow">Optional · Private</p><h2 id="optional-debt-title">Review card terms</h2></div><button type="button" className="debt-secondary" aria-label="Close card review" onClick={onClose}>Close</button></header><div className="optional-debt-scroll">
    <p>Use this only if a card or debt comparison would help. You can continue the challenge without debt, statements or a full budget.</p><p>Card payments and lower debt balances do not automatically count as saved money.</p><p>Household debt and this optional comparison keep separate reviewed terms. You can link a saved household card and review its values here; approval never changes household debt.</p>
    {notice && <p role="status" className="debt-notice">{notice}</p>}{(error || mutation.error || mutation.pending?.error) && <p role="alert" className="debt-warning">{error ?? mutation.error ?? mutation.pending?.error}</p>}
    {denied ? <p>Private card review is unavailable for this account or program. Financial details have been cleared. Your earlier request identity, if any, stays retained for a later authorized status check.</p> : <><button type="button" className="debt-secondary" disabled={loading || Boolean(mutation.pending)} onClick={refresh}>Refresh card review</button>{loading && <p role="status">Checking your current private terms…</p>}
    {mutation.pending && <section className="debt-notice" aria-label="Earlier card request"><h3>Resolve your earlier {mutation.pending.action === 'stage' ? 'pending proposal' : 'approval'} request</h3><p>Other changes stay blocked until this request is resolved. Only its account, program and request identity are retained when you close or reload.</p>{mutation.check && <button type="button" disabled={loading} onClick={() => void mutation.check!()}>Check earlier card result</button>}{mutation.retry && <button type="button" disabled={loading} onClick={() => void mutation.retry!()}>Retry exact card request</button>}{(mutation.reviewFresh || mutation.pending.fresh) && <><label className="debt-check"><input type="checkbox" checked={freshAccepted} onChange={event => setFreshAccepted(event.target.checked)}/> I will re-review this same action using its original request key.</label><button type="button" disabled={loading || !freshAccepted} onClick={() => void freshReview()}>Prepare original request review</button></>}</section>}
    {!loading && data && <><section aria-label="Qualified card comparison" className="debt-comparison"><h3>Current approved terms</h3>{data.summary.cards.some(row => row.household_terms_changed) && <p className="debt-warning">Some linked household values changed. This comparison keeps the separately approved card terms and dates; review the changed cards below.</p>}{!data.summary.cards.length && <p>No optional card terms approved yet. Having no debt is a valid starting point.</p>}<p>Known balance subtotal: <strong>{debtMoney(data.summary.known_balance_subtotal_cents)}</strong> · {data.summary.unknown_balance_count} unknown balances · {data.summary.stale_card_count} stale records</p><p>This is an incomplete optional list. Stale and archived records are excluded from the subtotal.</p><div className="debt-orders"><div><h4>Known-balance order · Snowball</h4>{data.summary.snowball_order.length ? <ol>{data.summary.snowball_order.map(id => <li key={id}>{labels.get(id) ?? 'Reviewed card'}</li>)}</ol> : <p>No eligible known positive balances.</p>}<p>Missing APRs or minimums still need review.</p></div><div><h4>Known single-APR order · Avalanche</h4>{data.summary.avalanche_order.length ? <ol>{data.summary.avalanche_order.map(id => <li key={id}>{labels.get(id) ?? 'Reviewed card'}</li>)}</ol> : <p>No eligible known single APRs.</p>}<p>Unknown balances/APRs, promotions and separate-rate segments are excluded.</p></div></div><p>Income, essentials, required payments and liquidity have not been verified here. No extra-payment amount or payoff date is recommended.</p></section>
    <button type="button" disabled={!editingAllowed()} onClick={() => { clearForms(); setEditor({}) }}>Add optional card terms</button><div className="debt-tabs" role="group" aria-label="Card record views">{(['cards', 'drafts', 'versions', 'candidates', 'household'] as const).map(kind => <button type="button" key={kind} className="debt-secondary" aria-pressed={tab === kind} onClick={() => setTab(kind)}>{({ cards: 'Cards', drafts: 'Pending drafts', versions: 'Approved history', candidates: 'Reviewed statement accounts', household: 'Saved household cards' })[kind]}</button>)}</div>
    <section aria-label={tab === 'versions' ? 'Approved card history' : tab === 'candidates' ? 'Reviewed liability accounts' : tab === 'household' ? 'Saved household cards' : tab === 'drafts' ? 'Pending card drafts' : 'Optional card records'}>
      {tab === 'cards' && data.pages.cards.records.map(card => <article key={card.id}><h3>{card.current_version?.terms.label ?? 'Unapproved card identity'}</h3>{card.current_version ? <><TermsView terms={card.current_version.terms}/>{data.summary.cards.find(row => row.card_id === card.id)?.source_stale && <p className="debt-warning">Approved source facts changed. Review a current mapping or explicitly use manual terms before comparing this card.</p>}<p>{card.source_tracked_account_id ? 'Explicit statement-account mapping' : 'Manually reviewed terms'}</p>{card.household_debt_id && <p>Linked household card: {String(card.current_version.household_debt_snapshot.label ?? 'Saved card')}. Each view keeps its own reviewed values.</p>}{data.summary.cards.find(row => row.card_id === card.id)?.household_terms_changed && <p className="debt-warning">The linked household card changed. These approved terms remain as of their reviewed date. Review current household values before using them as current terms.</p>}{card.household_debt_id && data.pages.household.records.some(row => row.household_debt_id === card.household_debt_id) && <button type="button" className="debt-secondary" disabled={!editingAllowed(card.id)} onClick={() => { clearForms(); setEditor({ card, useHousehold: true }) }}>Review current household terms for {card.current_version.terms.label}</button>}{data.summary.cards.find(row => row.card_id === card.id)?.promotional_expired && <p className="debt-warning">The promotional period has expired. Verify the successor APR before comparing rates.</p>}</> : <p>A pending proposal does not establish a balance, APR or payment.</p>}<button type="button" className="debt-secondary" disabled={!editingAllowed(card.id)} onClick={() => { clearForms(); setEditor({ card }) }}>Review {card.current_version ? 'correction' : 'terms'} for card {card.id}</button></article>)}
      {tab === 'drafts' && data.pages.drafts.records.map(draft => <article key={draft.id}><h3>{draft.terms.label} · {draft.status === 'pending' ? 'Pending proposal' : 'Already approved'}</h3><TermsView terms={draft.terms}/><p>{draft.reason}</p><button type="button" disabled={!approvalAllowed(draft.id) || draft.status !== 'pending'} onClick={() => void openDraft(draft.id)}>Review approval for draft {draft.id}</button></article>)}
      {tab === 'versions' && <><p>Earlier versions describe terms approved at that time. Do not add historical balances together.</p>{data.pages.versions.records.map(version => <article key={version.id}><h3>{version.terms.label} · Version {version.version_number}</h3><p>Approved {version.approved_at.slice(0, 10)} · {version.previous_version_id ? 'Correction' : 'First approval'}</p><TermsView terms={version.terms}/><p>{version.reason}</p><p>{version.household_debt_id ? `Linked household card: ${String(version.household_debt_snapshot.label ?? 'Saved card')}; saved values retained at approval.` : 'No household card link in this version.'}</p>{version.household_debt_id && <HouseholdSnapshot snapshot={version.household_debt_snapshot}/>}<p>{version.source_tracked_account_id ? 'Source facts retained in this approved version' : 'Manually reviewed terms'}</p></article>)}</>}
      {tab === 'candidates' && <><p>Only explicitly approved canonical liability accounts appear. A bank deposit account is not a credit card. A statement alone never approves debt terms.</p>{data.pages.candidates.records.map(candidate => <article key={candidate.source_account_identity_version_id}><h3>{candidate.label} · {candidate.statement_as_of_on}</h3><p>Proposed balance {debtMoney(candidate.proposed_terms.balance_cents)} · APR Unknown · Required minimum Unknown</p>{candidate.qualifications.map(text => <p key={text}>{text}</p>)}</article>)}</>}
      {tab === 'household' && <><p>Only active saved household credit cards appear. Their date and terms still need your review. No values are synchronized automatically.</p>{data.pages.household.records.map(candidate => <article key={candidate.household_debt_id}><h3>{candidate.label}</h3><p>Balance {debtMoney(candidate.proposed_terms.balance_cents)} · Minimum {debtMoney(candidate.proposed_terms.minimum_payment_cents)} · APR {debtApr(candidate.proposed_terms.apr_bps)}</p><p>{candidate.linked_card_id ? `Already linked to ${labels.get(candidate.linked_card_id) ?? 'an optional card'}. Review that card to avoid a duplicate.` : 'Available to link when reviewing optional terms.'}</p></article>)}</>}
      {!data.pages[tab].records.length && <p>No {tab === 'versions' ? 'approved history' : tab === 'candidates' ? 'reviewed liability accounts' : tab === 'household' ? 'saved household cards' : tab} on this page.</p>}{navigation(tab)}
    </section>
    {editor && <OptionalDebtTerms key={`${editor.card?.id ?? 'new'}:${Boolean(editor.useHousehold)}`} localToday={data.summary.local_today} card={editor.card} mapping={editor.card?.current_version ? debtMapping(editor.card.current_version) : null} candidates={data.pages.candidates.records} householdCandidates={data.pages.household.records} useHousehold={editor.useHousehold} busy={busy || Boolean(proposal)} onReview={reviewProposal}/>}
    {proposal && 'terms' in proposal && <section className="debt-proposal" aria-label="Pending proposal review"><h3 ref={reviewHeading} tabIndex={-1}>Review before saving a pending proposal</h3><h4>{proposal.terms.label}</h4><TermsView terms={proposal.terms}/><p>{proposal.source_mapping ? 'Explicit selected statement mapping; APR and payment terms are participant-reviewed.' : 'Manual terms; no current statement mapping.'}</p><p>{proposal.household_debt_mapping ? `Link to ${data.pages.household.records.find(row => row.household_debt_id === proposal.household_debt_mapping?.household_debt_id)?.label ?? 'the selected household card'}; household values stay unchanged.` : 'No saved household card link. Earlier links remain in approved history.'}</p>{proposal.household_debt_mapping && data.pages.household.records.find(row => row.household_debt_id === proposal.household_debt_mapping?.household_debt_id) && <HouseholdSnapshot snapshot={data.pages.household.records.find(row => row.household_debt_id === proposal.household_debt_mapping?.household_debt_id)!.snapshot}/>}<p>{proposal.reason}</p><p>This saves pending work only. The current approved version stays in place until separate approval.</p><label className="debt-check"><input type="checkbox" checked={accepted} onChange={event => setAccepted(event.target.checked)} disabled={busy}/> I reviewed this exact pending proposal and mapping choice.</label><button type="button" disabled={busy || !accepted} onClick={() => void mutation.submit('stage', proposal)}>Save pending proposal</button><button type="button" className="debt-secondary" disabled={busy} onClick={() => { setProposal(null); setAccepted(false) }}>Back to terms</button></section>}
    {draftReview && <section className="debt-proposal" aria-label="Card approval review"><h3 ref={reviewHeading} tabIndex={-1}>Review before approving card terms</h3><h4>{draftReview.draft.terms.label}</h4><TermsView terms={draftReview.draft.terms}/><p>{draftReview.draft.source_tracked_account_id ? 'Explicit statement-account mapping. This does not prove that APRs or minimums were printed in the file.' : 'Manual terms; no current statement mapping.'}</p><p>{draftReview.draft.household_debt_id ? `Link to ${String(draftReview.draft.household_debt_snapshot.label ?? 'the selected household card')}. Its reviewed snapshot is retained; household values stay unchanged.` : 'No saved household card link.'}</p>{draftReview.draft.household_debt_id && <HouseholdSnapshot snapshot={draftReview.draft.household_debt_snapshot}/>}<p>{draftReview.draft.reason}</p>{draftReview.card.current_version && <details><summary>Current approved terms remain in place</summary><TermsView terms={draftReview.card.current_version.terms}/></details>}<p>Approval appends a private immutable version. It does not move money, change your savings or update the full household budget.</p>{!canApprove && <p role="alert">{householdDraftChanged ? 'The saved household card changed after this proposal. Re-review its current values; this stale proposal cannot be approved.' : 'The approved head changed after this proposal. Review a correction against the current card; this stale proposal cannot be approved.'}</p>}<label className="debt-check"><input type="checkbox" checked={accepted} onChange={event => setAccepted(event.target.checked)} disabled={busy || !canApprove}/> I accept these exact reviewed card terms and mapping.</label><button type="button" disabled={busy || !canApprove || !accepted} onClick={() => void mutation.submit('approve', debtApproval(draftReview.draft))}>Approve reviewed card terms</button></section>}
    </> }</>}
  </div></section></div>
}
export type { DebtEnvelope }
