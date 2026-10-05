import { requestStorageError } from '../lib/durableRequestIdentity'
import { useEffect, useRef, useState } from 'react'
import type { PrivateAction, PrivacyApi, PrivacyCandidate, PrivacyScope, PrivacyState, PrivateProgram, RequestIdentity, SelectedRecord, RecordType, SharingKind, SourceLease, RemindersState } from '../lib/challengePrivacy'
import { assertPrivacyScope, candidateLabel, recordLabels, samePrivacyScope } from '../lib/challengePrivacy'
import { privacyApi } from '../lib/privacyApi'
import { clearPrivacyRecovery, readPrivacyRecovery, savePrivacyRecovery } from '../lib/privacyRecovery'
import { createOperationIdempotencyKey } from '../lib/operationIdempotency'
import './ChallengePrivacyDialog.css'

type Props = { actorScope: PrivacyScope | null; participant: boolean; initialEnrollmentId?: number; documentImportId?: number; onClose: () => void; api?: PrivacyApi }
type Review = { action: PrivateAction; input: object; title: string; lines: string[]; reflectionId?: number }
type Pending = { identity: RequestIdentity; input?: object; state: 'working' | 'uncertain' | 'unknown'; error: string }
const message = (error: unknown) => error instanceof Error ? error.message : 'This private request could not be completed.'
const statusCode = (error: unknown) => error && typeof error === 'object' && 'status' in error ? Number(error.status) : null
const privateTime = (value: string) => new Intl.DateTimeFormat('en-US', { timeZone: 'Pacific/Guam', dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value)) + ' Guam'
const recordScope = (rows: SelectedRecord[]) => rows.length ? rows.map((row) => `${recordLabels[row.record_type]} · exact record ${row.record_id}`).join('; ') : 'No records selected'

export function ChallengePrivacyDialog(props: Props) {
  const key = props.actorScope ? `${props.actorScope.user_id}:${props.actorScope.household_id}:${props.participant}` : 'signed-out'
  return <PrivacySession key={key} {...props} api={props.api ?? privacyApi} />
}

function PrivacySession({ actorScope, participant, initialEnrollmentId, documentImportId, onClose, api }: Props & { api: PrivacyApi }) {
  const dialog = useRef<HTMLDialogElement>(null)
  const controller = useRef(new AbortController())
  const live = useRef(true)
  const metadataRequest = useRef<AbortController | null>(null)
  const programPageRequest = useRef<AbortController | null>(null)
  const [programsPaging, setProgramsPaging] = useState(false)
  const [programs, setPrograms] = useState<PrivateProgram[]>([])
  const [cursor, setCursor] = useState<number | null>(null)
  const [enrollmentId, setEnrollmentId] = useState<number | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [denied, setDenied] = useState(!participant || !actorScope)
  const [revision, setRevision] = useState(0)
  const [review, setReview] = useState<Review | null>(null)
  const [accepted, setAccepted] = useState(false)
  const [notice, setNotice] = useState('')
  const [pending, setPending] = useState<Pending | null>(() => actorScope ? (() => { const identity = readPrivacyRecovery(actorScope); return identity ? { identity, state: 'uncertain', error: 'Check the earlier request before making another change.' } : null })() : null)
  const own = () => live.current && !controller.current.signal.aborted
  useEffect(() => {
    live.current = true
    const request = new AbortController()
    controller.current = request
    const previous = document.activeElement as HTMLElement | null
    const node = dialog.current
    node?.showModal()
    return () => { live.current = false; request.abort(); node?.close(); previous?.focus() }
  }, [])
  useEffect(() => {
    if (!actorScope || !participant) return
    const request = new AbortController()
    metadataRequest.current = request
    let active = true
    const current = () => active && !request.signal.aborted && own()
    queueMicrotask(() => { if (current()) { setLoading(true); setProgramsPaging(false); setCursor(null); setError(''); setPrograms([]); setEnrollmentId(null) } })
    void (async () => {
      let page = await api.controls(null, request.signal)
      assertPrivacyScope(page, actorScope)
      const rows = [...page.records]
      const seen = new Set<number>()
      while (initialEnrollmentId && !rows.some((row) => row.id === initialEnrollmentId) && page.next_cursor !== null) {
        if (seen.has(page.next_cursor)) throw new Error('Program pagination did not advance. Close and reopen your controls.')
        seen.add(page.next_cursor)
        page = await api.controls(page.next_cursor, request.signal)
        assertPrivacyScope(page, actorScope); rows.push(...page.records)
      }
      if (current()) {
        setError(''); setDenied(false); setPrograms(rows); setCursor(page.next_cursor)
        setEnrollmentId(initialEnrollmentId ? rows.find((row) => row.id === initialEnrollmentId)?.id ?? null : rows[0]?.id ?? null)
        if (initialEnrollmentId && !rows.some((row) => row.id === initialEnrollmentId)) setError('The selected program is unavailable. Choose one of your own programs.')
        setLoading(false)
      }
    })().catch((failure) => { if (current()) { setError(message(failure)); setLoading(false); if ([401, 403].includes(statusCode(failure) ?? 0)) { setDenied(true); setPending(null) } } })
    return () => { active = false; request.abort(); if (programPageRequest.current === request) programPageRequest.current = null }
  }, [actorScope, participant, initialEnrollmentId, api])
  async function morePrograms() {
    if (!actorScope || loading || cursor === null || programPageRequest.current) return
    const request = metadataRequest.current
    if (!request || request.signal.aborted) return
    programPageRequest.current = request
    setProgramsPaging(true)
    setError('')
    const current = () => own() && metadataRequest.current === request && !request.signal.aborted
    try { const page = await api.controls(cursor, request.signal); assertPrivacyScope(page, actorScope); if (current()) { setPrograms((rows) => [...rows, ...page.records]); setCursor(page.next_cursor) } }
    catch (failure) { if (current()) setError(message(failure)) }
    finally { if (programPageRequest.current === request) { programPageRequest.current = null; if (current()) setProgramsPaging(false) } }
  }
  function stage(value: Review) {
    if (pending && !(pending.state === 'unknown' && !pending.input && pending.identity.enrollmentId === enrollmentId && pending.identity.action === value.action && pending.identity.reflectionId === value.reflectionId)) return
    setReview(value); setAccepted(false); setNotice(''); setError('')
  }
  async function perform(identity: RequestIdentity, input: object) {
    if (!actorScope || !samePrivacyScope(identity.scope, actorScope)) return
    if (!savePrivacyRecovery(identity)) { setError(requestStorageError); return }
    setPending({ identity, input, state: 'working', error: '' })
    try {
      await api.mutate(identity, input, controller.current.signal)
      if (!own()) return
      clearPrivacyRecovery(identity); setPending(null); setReview(null); setAccepted(false); setNotice('Your reviewed choice was saved.'); setRevision((value) => value + 1)
    } catch (failure) {
      if (!own()) return
      const code = statusCode(failure)
      if (code === 409 && pending?.identity.key === identity.key) {
        setPending({ identity, state: 'uncertain', error: 'The fresh review conflicted with this retained request. Check the earlier result before continuing.' }); setReview(null); setAccepted(false)
      } else if ([400, 401, 403, 404, 409, 422].includes(code ?? 0)) {
        clearPrivacyRecovery(identity); setPending(null); setReview(null); setAccepted(false); setError(message(failure)); setRevision((value) => value + 1)
        if (code === 401) { setDenied(true); setPrograms([]); setEnrollmentId(null) }
      } else setPending({ identity, input, state: 'uncertain', error: 'The server did not confirm this change. Check its result before retrying.' })
    }
  }
  async function check() {
    if (!pending || !actorScope) return
    const saved = pending
    setPending({ ...saved, state: 'working' })
    try {
      const result = await api.status(saved.identity, controller.current.signal)
      if (result.actor_scope || (saved.identity.action !== 'erase' && result.state !== 'in_flight')) assertPrivacyScope(result, actorScope)
      if (!own()) return
      if (result.state === 'committed') { clearPrivacyRecovery(saved.identity); setPending(null); setReview(null); setNotice('The earlier request was saved once.'); setRevision((value) => value + 1) }
      else setPending({ ...saved, state: result.state === 'unknown' && result.can_retry !== false ? 'unknown' : 'uncertain', error: result.state === 'in_flight' ? 'The earlier request is still processing. Check again.' : saved.input ? 'No saved result found. You may retry the exact reviewed request with its original identifier.' : 'No saved result found. Re-review the same action before submitting with this original identifier.' })
    } catch (failure) { if (own()) { setPending({ ...saved, state: 'uncertain', error: message(failure) }); if ([401, 403, 404].includes(statusCode(failure) ?? 0)) { setPending(null); setDenied(true); setPrograms([]); setEnrollmentId(null) } } }
  }
  useEffect(() => { if (review) dialog.current?.querySelector<HTMLElement>('#privacy-review-title')?.focus() }, [review])
  function containFocus(event: React.KeyboardEvent<HTMLDialogElement>) {
    if (event.key !== 'Tab') return
    const nodes = [...event.currentTarget.querySelectorAll<HTMLElement>('button, input, select, textarea, summary, a[href], [tabindex]')].filter((node) => node.tabIndex >= 0 && !node.matches(':disabled') && node.getClientRects().length > 0)
    const first = nodes[0]; const last = nodes.at(-1)
    if (!first || !last) { event.preventDefault(); return }
    event.preventDefault()
    const current = nodes.indexOf(document.activeElement as HTMLElement)
    const next = current < 0 ? (event.shiftKey ? nodes.length - 1 : 0) : (current + (event.shiftKey ? -1 : 1) + nodes.length) % nodes.length
    nodes[next].focus()
  }
  const blocked = Boolean(pending && !(pending.state === 'unknown' && !pending.input && pending.identity.enrollmentId === enrollmentId))
  const allowedAction = pending ? pending.state === 'unknown' && !pending.input ? pending.identity.action : null : undefined
  return <dialog ref={dialog} className="challenge-privacy-dialog" aria-labelledby="privacy-title" onKeyDown={containFocus} onCancel={(event) => { event.preventDefault(); onClose() }}>
    <header><div><p className="privacy-eyebrow">Your controls</p><h2 id="privacy-title">Privacy, help & reminders</h2></div><button type="button" className="privacy-close" aria-label="Close privacy controls" onClick={onClose}>×</button></header>
    <div className="privacy-scroll">
      <p className="privacy-intro">Statements, chat and feelings are private by default. You choose each sharing purpose separately. Feelings stay private.</p>
      {denied ? <p role="alert">These controls are available only to the participant who owns this enrollment. Sign in to your participant account.</p> : <>
        {loading && <p role="status">Loading your programs…</p>}
        {!loading && programs.length === 0 && !error && <p>No savings enrollment yet. These controls become available after you accept a challenge.</p>}
        {programs.length > 0 && <label className="privacy-field">Program<select value={enrollmentId ?? ''} onChange={(event) => { setEnrollmentId(Number(event.target.value)); setReview(null); setNotice(''); setError('') }}><option value="" disabled>Choose your program</option>{programs.map((row) => <option key={row.id} value={row.id}>{row.program_name} · {row.status}</option>)}</select></label>}
        {cursor !== null && <button type="button" disabled={loading || programsPaging} onClick={() => void morePrograms()}>Load more programs</button>}
        {pending && <section className="privacy-notice" aria-label="Earlier request"><p role="status">{pending.error || 'Saving your reviewed choice…'}</p><p>Request: <code>{pending.identity.key}</code> · {pending.identity.action}</p><button type="button" disabled={pending.state === 'working'} onClick={() => void check()}>Check earlier request</button>{pending.state === 'unknown' && pending.input && <button type="button" onClick={() => void perform(pending.identity, pending.input!)}>Retry exact reviewed request</button>}{pending.state === 'unknown' && !pending.input && <p>Select the same program and re-review {pending.identity.action}. Other changes remain blocked.</p>}</section>}
        {error && <p className="privacy-error" role="alert">{error}</p>}{notice && <p className="privacy-notice" role="status">{notice}</p>}
        {review ? <section className="privacy-review" aria-labelledby="privacy-review-title"><p className="privacy-eyebrow">Review before approval</p><h3 id="privacy-review-title" tabIndex={-1}>{review.title}</h3><ul>{review.lines.map((line, i) => <li key={i}>{line}</li>)}</ul><label className="privacy-check"><input type="checkbox" checked={accepted} onChange={(event) => setAccepted(event.target.checked)} />I understand and approve this exact change.</label><div className="privacy-actions"><button type="button" disabled={!accepted || Boolean(pending && (pending.state !== 'unknown' || pending.input))} onClick={() => { if (enrollmentId && actorScope) void perform(pending?.identity ?? { scope: actorScope, enrollmentId, action: review.action, key: createOperationIdempotencyKey(), ...(review.reflectionId ? { reflectionId: review.reflectionId } : {}) }, review.input) }}>Approve reviewed change</button><button type="button" className="privacy-secondary" disabled={pending?.state === 'working'} onClick={() => setReview(null)}>Back without approval</button></div></section> : enrollmentId && actorScope && <ProgramControls key={`${enrollmentId}:${revision}`} scope={actorScope} enrollmentId={enrollmentId} documentImportId={documentImportId} api={api} blocked={blocked} allowedAction={allowedAction} stage={stage} />}
      </>}
    </div>
  </dialog>
}

type ControlsProps = { scope: PrivacyScope; enrollmentId: number; documentImportId?: number; api: PrivacyApi; blocked: boolean; allowedAction: PrivateAction | null | undefined; stage: (review: Review) => void }
function ProgramControls({ scope, enrollmentId, documentImportId, api, blocked, allowedAction, stage }: ControlsProps) {
  const [data, setData] = useState<PrivacyState | null>(null)
  const [error, setError] = useState('')
  const abort = useRef(new AbortController())
  const live = useRef(true)
  const [more, setMore] = useState(false)
  useEffect(() => {
    const request = new AbortController(); abort.current = request; live.current = true
    const current = () => live.current && abort.current === request && !request.signal.aborted
    queueMicrotask(() => { if (current()) { setData(null); setError(''); setMore(false) } })
    void api.privacy(enrollmentId, null, request.signal).then((result) => { assertPrivacyScope(result, scope); if (current()) { setError(''); setData(result) } }).catch((failure) => { if (current()) { setError(message(failure)); setData(null) } })
    return () => { request.abort(); if (abort.current === request) live.current = false }
  }, [api, scope, enrollmentId])
  async function moreReflections() {
    if (!data?.reflections_next_cursor || more) return
    setMore(true)
    const request = abort.current
    const current = () => live.current && abort.current === request && !request.signal.aborted
    try { const page = await api.privacy(enrollmentId, data.reflections_next_cursor, request.signal); assertPrivacyScope(page, scope); if (current()) setData((previous) => previous && { ...previous, erasable_reflections: [...previous.erasable_reflections, ...page.erasable_reflections], reflections_next_cursor: page.reflections_next_cursor }) }
    catch (failure) { if (current()) setError(message(failure)) } finally { if (current()) setMore(false) }
  }
  const can = (action: PrivateAction) => !blocked && (allowedAction === undefined || allowedAction === action)
  if (error) return <p className="privacy-error" role="alert">{error}</p>
  if (!data) return <p role="status">Loading your private control metadata…</p>
  const name = (id: number | null) => id === null ? 'Scheduled coarse sponsor report' : data.recipients.find((row) => row.id === id)?.name ?? `Previously selected recipient ${id}`
  function revoke(grant: PrivacyState['grants'][number]) { stage({ action: 'consent', title: 'Revoke this sharing purpose', lines: [`Recipient: ${name(grant.recipient_user_id)}`, `Purpose: ${grant.kind}`, 'New reads will lose this grant. Copies already downloaded cannot be recalled.'], input: { enrollment_id: enrollmentId, kind: grant.kind, recipient_user_id: grant.recipient_user_id, granted: false, selected_records: [], expires_at: null, policy_version: data!.policy_version, expected_grant_id: grant.id, expected_lock_version: grant.lock_version } }) }
  return <div className="privacy-sections">
    <details open><summary>Sharing choices<span>Private unless you approve</span></summary><div className="privacy-detail"><p>Pausing or leaving a program still lets you revoke access. New sharing may be unavailable while the program is held.</p>{data.grants.length === 0 ? <p>No sharing grants.</p> : <ul className="privacy-records">{data.grants.map((grant) => <li key={grant.id}><strong>{name(grant.recipient_user_id)}</strong><p>{grant.kind.replaceAll('_', ' ')} · {grant.granted ? 'Granted' : 'Revoked'}{grant.expires_at && ` · expires ${privateTime(grant.expires_at)}`}</p>{grant.selected_records.length > 0 && <p>{recordScope(grant.selected_records)}</p>}{grant.granted && <button type="button" disabled={!can('consent')} onClick={() => revoke(grant)}>Review revoke sharing</button>}</li>)}</ul>}<SharingForm data={data} api={api} scope={scope} disabled={!can('consent')} stage={stage} /></div></details>
    <details><summary>Ask for help<span>Choose who receives your request</span></summary><div className="privacy-detail"><SupportForm data={data} api={api} scope={scope} disabled={!can('support_request')} stage={stage} />{data.support_requests.map((ticket) => <article key={ticket.id}><h4>{name(ticket.recipient_user_id)} · {ticket.issue_kind}</h4><p>{ticket.message}</p><p>Status: {ticket.status}. A request alone grants no extra record access.</p><SupportGrantForm data={data} ticketId={ticket.id} api={api} scope={scope} disabled={!can('support_grant')} stage={stage} /></article>)}{data.support_access.map((access) => <article key={access.id}><h4>Temporary access for {name(access.recipient_user_id)}</h4><p>{recordScope(access.selected_records)}</p><p>{access.revoked_at ? 'Revoked' : `Expires ${privateTime(access.expires_at)}`}</p>{!access.revoked_at && <button type="button" disabled={!can('support_revoke')} onClick={() => stage({ action: 'support_revoke', title: 'Revoke temporary support access', lines: [`Recipient: ${name(access.recipient_user_id)}`, recordScope(access.selected_records), 'New reads will be denied. Downloaded copies cannot be recalled.'], input: { enrollment_id: enrollmentId, access_id: access.id, expected_lock_version: access.lock_version } })}>Review revoke support access</button>}</article>)}</div></details>
    <details><summary>Original source use<span>Exact expiry and global revocation</span></summary><div className="privacy-detail"><SourceControls {...{ enrollmentId, documentImportId, api, scope, stage }} can={can} knownSources={data.grants.flatMap((grant) => grant.selected_records).filter((row) => row.record_type === 'document_source').map((row) => row.record_id)} /></div></details>
    <details><summary>Erase optional feelings<span>All saved text versions, no money changes</span></summary><div className="privacy-detail"><p>Choose by the saved date. This view does not read purchase details or feelings. Erasure removes optional text from all historical versions and retains redacted metadata; financial records remain intact.</p>{data.erasable_reflections.length === 0 && <p>No reflection metadata to erase.</p>}<ul className="privacy-records">{data.erasable_reflections.map((reflection) => <li key={reflection.id}><span>Reflection saved {privateTime(reflection.created_at)}</span>{reflection.erased_at ? <p>Erased {privateTime(reflection.erased_at)}</p> : <button type="button" disabled={!can('erase') || !reflection.current_version_id} onClick={() => stage({ action: 'erase', reflectionId: reflection.id, title: 'Erase optional reflection text', lines: [`Reflection ${reflection.id}, saved ${privateTime(reflection.created_at)}`, 'All historical optional feeling text will be erased. This cannot be undone.', 'Purchases, savings and approved financial history will remain unchanged.'], input: { erase_accepted: true, expected_version_id: reflection.current_version_id, expected_head_lock_version: reflection.lock_version } })}>Review erase reflection {reflection.id}</button>}</li>)}</ul>{data.reflections_next_cursor !== null && <button type="button" disabled={more} onClick={() => void moreReflections()}>{more ? 'Loading…' : 'Load more reflection metadata'}</button>}</div></details>
    <details><summary>Daily reminders<span>Optional, generic and quiet overnight</span></summary><div className="privacy-detail"><ReminderControls {...{ enrollmentId, api, scope, stage }} can={can} /></div></details>
  </div>
}

function ExactRecords({ api, enrollmentId, scope, selected, onChange, disabled = false, onlySources = false }: { api: PrivacyApi; enrollmentId: number; scope: PrivacyScope; selected: PrivacyCandidate[]; onChange: (records: PrivacyCandidate[]) => void; disabled?: boolean; onlySources?: boolean }) {
  const [type, setType] = useState<RecordType>('document_source')
  const [page, setPage] = useState<PrivacyCandidate[]>([])
  const [cursor, setCursor] = useState<number | null>(null)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)
  const abort = useRef<AbortController | null>(null)
  useEffect(() => () => abort.current?.abort(), [])
  async function load(next: number | null = null) {
    abort.current?.abort(); const request = new AbortController(); abort.current = request; setLoading(true); setError('')
    try { const result = await api.candidates(enrollmentId, type, next, request.signal); assertPrivacyScope(result, scope); if (!request.signal.aborted) { setPage((rows) => next === null ? result.records : [...rows, ...result.records]); setCursor(result.next_cursor) } }
    catch (failure) { if (!request.signal.aborted) { setPage([]); setCursor(null); onChange([]); setError(message(failure)) } } finally { if (!request.signal.aborted) setLoading(false) }
  }
  return <fieldset className="privacy-selector" disabled={disabled}><legend>Exact records (optional unless granting detailed access)</legend><p>Sharing includes the entire selected record, not just its preview. An original statement can expose every row and identifying detail in that file. Chat previews may be excerpts; full selected messages are shared. Feelings cannot be selected.</p><label className="privacy-field">Record type<select value={type} onChange={(event) => { abort.current?.abort(); setType(event.target.value as RecordType); setPage([]); setCursor(null); setError(''); setLoading(false) }}>{Object.entries(recordLabels).filter(([key]) => !onlySources || key === 'document_source').map(([key, label]) => <option key={key} value={key}>{label}</option>)}</select></label><button type="button" disabled={loading} onClick={() => void load()}>{loading ? 'Loading exact records…' : 'Find exact records'}</button>{error && <p role="alert">{error}</p>}{page.length === 0 && !loading && !error && <p>No records loaded. Nothing is selected by default.</p>}<ul className="privacy-records">{page.map((row) => { const checked = selected.some((item) => item.record_type === row.record_type && item.record_id === row.record_id); return <li key={`${row.record_type}:${row.record_id}`}><label className="privacy-check"><input type="checkbox" checked={checked} disabled={!checked && selected.length >= 20} onChange={() => onChange(checked ? selected.filter((item) => !(item.record_type === row.record_type && item.record_id === row.record_id)) : [...selected, row])} /><span>{candidateLabel(row)}<small>Entire {recordLabels[row.record_type].toLowerCase()} record {row.record_id}{row.preview.excerpt_only ? ' · preview is an excerpt' : ''}</small></span></label></li> })}</ul>{cursor !== null && <button type="button" disabled={loading} onClick={() => void load(cursor)}>Load more exact records</button>}{selected.length > 0 && <p>{selected.length}/20 exact records selected: {recordScope(selected)}</p>}</fieldset>
}

const selectedIds = (rows: PrivacyCandidate[]): SelectedRecord[] => rows.map(({ record_type, record_id }) => ({ record_type, record_id }))
const expiryAfter = (hours: number) => new Date(Date.now() + hours * 3600000).toISOString()
function SharingForm({ data, api, scope, disabled, stage }: { data: PrivacyState; api: PrivacyApi; scope: PrivacyScope; disabled: boolean; stage: (review: Review) => void }) {
  const [kind, setKind] = useState<SharingKind>('coach_summary')
  const [recipient, setRecipient] = useState('')
  const [hours, setHours] = useState(24)
  const [selected, setSelected] = useState<PrivacyCandidate[]>([])
  function review() {
    const id = kind === 'sponsor_aggregate' ? null : Number(recipient)
    const expires = kind === 'selected_details' ? expiryAfter(hours) : null
    const grant = data.grants.find((row) => row.kind === kind && row.recipient_user_id === id)
    stage({ action: 'consent', title: 'Grant this separate sharing purpose', lines: [`Recipient: ${id === null ? 'Fixed scheduled coarse sponsor report; no individual recipient' : data.recipients.find((row) => row.id === id)?.name}`, `Purpose: ${kind.replaceAll('_', ' ')}`,
      kind === 'coach_summary' ? 'Share approved monetary summaries only. No statements, chat or feelings.' : kind === 'sponsor_aggregate' ? 'Voluntary consent to fixed coarse aggregate reports with small-group suppression. No individual drilldown or exact individual outcomes.' : `Share ENTIRE selected records: ${recordScope(selected)}. Previews do not limit what is shared.`,
      ...(kind === 'selected_details' ? selected.map((row) => candidateLabel(row)) : []), expires ? `Expires: ${privateTime(expires)}` : 'Until you revoke this grant.', 'Downloaded copies cannot be recalled. Feelings remain private.'], input: { enrollment_id: data.enrollment_id, kind, recipient_user_id: id, granted: true, selected_records: kind === 'selected_details' ? selectedIds(selected) : [], expires_at: expires, policy_version: data.policy_version, expected_grant_id: grant?.id ?? null, expected_lock_version: grant?.lock_version ?? 0 } })
  }
  return <form onSubmit={(event) => { event.preventDefault(); review() }}><fieldset disabled={disabled}><legend>Review a new sharing choice</legend><label className="privacy-field">Purpose<select value={kind} onChange={(event) => { setKind(event.target.value as SharingKind); setSelected([]) }}><option value="coach_summary">Approved monetary summary</option><option value="selected_details">Exact selected records</option><option value="sponsor_aggregate">Coarse sponsor aggregate</option></select></label>{kind !== 'sponsor_aggregate' && <label className="privacy-field">Exact recipient<select required value={recipient} onChange={(event) => setRecipient(event.target.value)}><option value="">Choose a recipient</option>{data.recipients.map((row) => <option key={row.id} value={row.id}>{row.name} · {row.role}</option>)}</select></label>}{kind === 'selected_details' && <><ExactRecords {...{ api, scope, selected }} enrollmentId={data.enrollment_id} onChange={setSelected} /><label className="privacy-field">Access duration<select value={hours} onChange={(event) => setHours(Number(event.target.value))}><option value={24}>24 hours</option><option value={168}>7 days</option><option value={720}>30 days</option></select></label></>}<button disabled={kind === 'selected_details' && selected.length === 0} type="submit">Review sharing choice</button></fieldset></form>
}

function SupportForm({ data, api, scope, disabled, stage }: { data: PrivacyState; api: PrivacyApi; scope: PrivacyScope; disabled: boolean; stage: (review: Review) => void }) {
  const [recipient, setRecipient] = useState(''); const [kind, setKind] = useState('technical'); const [text, setText] = useState(''); const [selected, setSelected] = useState<PrivacyCandidate[]>([])
  return <form onSubmit={(event) => { event.preventDefault(); stage({ action: 'support_request', title: 'Create this private help request', lines: [`Recipient: ${data.recipients.find((row) => row.id === Number(recipient))?.name}`, `Purpose: ${kind}`, text, `Optional references: ${recordScope(selected)}`, 'Creating a request does not grant access to these records. Approve temporary record access separately. No WhatsApp message or email will be sent.'], input: { enrollment_id: data.enrollment_id, recipient_user_id: Number(recipient), issue_kind: kind, message: text, selected_records: selectedIds(selected) } }) }}><fieldset disabled={disabled}><legend>Private help request</legend><label className="privacy-field">Help recipient<select required value={recipient} onChange={(event) => setRecipient(event.target.value)}><option value="">Choose who can help</option>{data.recipients.map((row) => <option key={row.id} value={row.id}>{row.name} · {row.role}</option>)}</select></label><label className="privacy-field">Issue<select value={kind} onChange={(event) => setKind(event.target.value)}>{['technical', 'coaching', 'access', 'other'].map((value) => <option key={value}>{value}</option>)}</select></label><label className="privacy-field">Your message<textarea required maxLength={500} value={text} onChange={(event) => setText(event.target.value)} rows={4} /></label><small>{text.length}/500 characters</small><details><summary>Optional exact record references</summary><ExactRecords {...{ api, scope, selected }} enrollmentId={data.enrollment_id} onChange={setSelected} /></details><button type="submit" disabled={!text.trim()}>Review help request</button></fieldset></form>
}

function SupportGrantForm({ data, ticketId, api, scope, disabled, stage }: { data: PrivacyState; ticketId: number; api: PrivacyApi; scope: PrivacyScope; disabled: boolean; stage: (review: Review) => void }) {
  const [selected, setSelected] = useState<PrivacyCandidate[]>([]); const [reason, setReason] = useState(''); const [hours, setHours] = useState(1)
  const ticket = data.support_requests.find((row) => row.id === ticketId)!
  return <details><summary>Grant exact records for this ticket</summary><form onSubmit={(event) => { event.preventDefault(); const expires = expiryAfter(hours); stage({ action: 'support_grant', title: 'Grant temporary support access', lines: [`Recipient: ${data.recipients.find((row) => row.id === ticket.recipient_user_id)?.name ?? ticket.recipient_user_id}`, `Ticket: ${ticket.id}`, `Entire selected records: ${recordScope(selected)}`, ...selected.map(candidateLabel), `Reason: ${reason}`, `Expires: ${privateTime(expires)} (at most 24 hours)`, 'The recipient can read the entire selected records until expiry or revocation. Downloaded copies cannot be recalled.'], input: { enrollment_id: data.enrollment_id, ticket_id: ticket.id, recipient_user_id: ticket.recipient_user_id, selected_records: selectedIds(selected), reason, expires_at: expires, expected_ticket_lock_version: ticket.lock_version } }) }}><fieldset disabled={disabled}><ExactRecords {...{ api, scope, selected }} enrollmentId={data.enrollment_id} onChange={setSelected} /><label className="privacy-field">Reason for record access<textarea required maxLength={500} value={reason} onChange={(event) => setReason(event.target.value)} /></label><label className="privacy-field">Support duration<select value={hours} onChange={(event) => setHours(Number(event.target.value))}>{[1, 4, 24].map((value) => <option key={value} value={value}>{value} hours</option>)}</select></label><button disabled={selected.length === 0 || !reason.trim()} type="submit">Review temporary support access</button></fieldset></form></details>
}

function SourceControls({ api, enrollmentId, documentImportId, scope, can, stage, knownSources }: Pick<ControlsProps, 'api' | 'enrollmentId' | 'documentImportId' | 'scope' | 'stage'> & { can: (action: PrivateAction) => boolean; knownSources: number[] }) {
  const [selected, setSelected] = useState<PrivacyCandidate[]>([])
  const [source, setSource] = useState<SourceLease | null>(null); const [error, setError] = useState(''); const [sourceId, setSourceId] = useState(documentImportId ? String(documentImportId) : '')
  const abort = useRef<AbortController | null>(null)
  useEffect(() => () => abort.current?.abort(), [])
  async function load(id: number) { abort.current?.abort(); const request = new AbortController(); abort.current = request; setSource(null); setError(''); try { const result = await api.source(enrollmentId, id, request.signal); if (result.document_import_id !== id) throw new Error('The source response did not match the selected original. Reopen its controls.'); if (!request.signal.aborted) setSource(result) } catch (failure) { if (!request.signal.aborted) setError(message(failure)) } }
  return <><p>There is no implicit extension when you join another program. Review the exact personal end date plus 30 days. Provider backup retention has not been verified.</p><details><summary>Find an original source</summary><ExactRecords onlySources {...{ api, scope, selected }} enrollmentId={enrollmentId} onChange={(rows) => { const sources = rows.filter((row) => row.record_type === 'document_source'); setSelected(sources); if (sources.length) setSourceId(String(sources.at(-1)!.record_id)) }} /></details>{knownSources.length > 0 && <label className="privacy-field">Previously shared original<select value={sourceId} onChange={(event) => { setSourceId(event.target.value); setSource(null) }}><option value="">Choose an original</option>{[...new Set(knownSources)].map((id) => <option key={id} value={id}>Original document {id}</option>)}</select></label>}<p>During a hold, open these controls from the original source in Statements to review its known identifier without loading financial candidates.</p>{sourceId && <button type="button" onClick={() => void load(Number(sourceId))}>Review source {sourceId} use</button>}{error && <p role="alert">{error}</p>}{source && <article><h4>Original source {source.document_import_id}</h4><p>{source.source_available ? 'Source currently available' : 'Source unavailable'} · approved structured financial records are retained.</p><p>Disclosed expiry for this enrollment: {privateTime(source.expected_expires_at)}.</p><ul>{source.affected_uses.map((use) => <li key={use.id}>Enrollment {use.enrollment_id} · {use.revoked ? 'revoked' : `expires ${privateTime(use.expires_at)}`}</li>)}</ul><p>Downloaded copies cannot be recalled. Physical deletion is durable retry work; provider backup retention is unverified.</p><div className="privacy-actions"><button type="button" disabled={!source.source_available || !can('source_authorize')} onClick={() => stage({ action: 'source_authorize', title: 'Authorize this exact source-use expiry', lines: [`Original source ${source.document_import_id}`, `This enrollment expires at ${privateTime(source.expected_expires_at)} under ${source.disclosure_version}.`, 'Approved structured facts remain. Downloaded copies cannot be recalled. Provider backup retention is unverified.'], input: { enrollment_id: enrollmentId, document_import_id: source.document_import_id, disclosure_version: source.disclosure_version, expected_expires_at: source.expected_expires_at, expected_use_id: source.expected_use_id, expected_lock_version: source.expected_lock_version } })}>Review authorize source use</button><button type="button" className="privacy-danger" disabled={!can('source_revoke')} onClick={() => stage({ action: 'source_revoke', title: 'Revoke this original globally', lines: [`Original source ${source.document_import_id}. This applies to ALL affected enrollments, not just this program.`, ...source.affected_uses.map((use) => `Enrollment ${use.enrollment_id}: ${use.revoked ? 'already revoked' : privateTime(use.expires_at)}`), 'New source reads stop immediately. Physical cleanup may remain pending and retries durably.', 'Approved structured facts remain. Downloaded copies cannot be recalled. Provider backup retention is unverified.'], input: { enrollment_id: enrollmentId, document_import_id: source.document_import_id, expected_affected_uses_digest: source.expected_affected_uses_digest } })}>Review global source revocation</button></div></article>}</>
}

function ReminderControls({ api, enrollmentId, scope, can, stage }: Pick<ControlsProps, 'api' | 'enrollmentId' | 'scope' | 'stage'> & { can: (action: PrivateAction) => boolean }) {
  const [data, setData] = useState<RemindersState | null>(null); const [error, setError] = useState('')
  useEffect(() => { const request = new AbortController(); void api.reminders(enrollmentId, request.signal).then((result) => { assertPrivacyScope(result, scope); if (!request.signal.aborted) setData(result) }).catch((failure) => { if (!request.signal.aborted) setError(message(failure)) }); return () => request.abort() }, [api, scope, enrollmentId])
  return <>{error && <p role="alert">{error}</p>}{!data && !error && <p role="status">Loading reminder preferences…</p>}{data && <><p>All times use {data.time_zone}. Reminders contain no amounts, merchants or feelings. Dismissing a reminder does not create a check-in or a no-spend day.</p>{!data.email_delivery_enabled && <p className="privacy-notice">Email delivery is not configured. Email consent is separate; enabling it will not activate delivery until the operator configures it.</p>}{data.preferences.map((preference) => <ReminderForm key={preference.channel} preference={preference} enrollmentId={enrollmentId} disabled={!can('preference')} stage={stage} />)}{data.reminder && <article><h4>{data.reminder.title}</h4><p>{data.reminder.body}</p><button type="button" disabled={!can('dismiss')} onClick={() => stage({ action: 'dismiss', title: 'Dismiss this in-app reminder', lines: ['Dismissal does not record spending, no-spend or a check-in.'], input: { enrollment_id: enrollmentId, reminder_id: data.reminder!.id, expected_lock_version: data.reminder!.lock_version } })}>Review dismiss reminder</button></article>}</>}</>
}

function ReminderForm({ preference, enrollmentId, disabled, stage }: { preference: RemindersState['preferences'][number]; enrollmentId: number; disabled: boolean; stage: (review: Review) => void }) {
  const [enabled, setEnabled] = useState(preference.enabled); const [time, setTime] = useState(preference.local_time); const [start, setStart] = useState(preference.quiet_start); const [end, setEnd] = useState(preference.quiet_end)
  return <form onSubmit={(event) => { event.preventDefault(); stage({ action: 'preference', title: `Review ${preference.channel === 'email' ? 'separate email consent' : 'in-app reminder preference'}`, lines: [`Channel: ${preference.channel === 'email' ? 'Email (separate optional consent)' : 'In-app'}`, `${enabled ? 'Enable' : 'Disable'} generic daily reminder`, `Local reminder: ${time}; quiet hours: ${start}–${end}, Pacific/Guam.`, 'No financial details or feelings in notifications. Missing or dismissing a reminder means no check-in was recorded.'], input: { enrollment_id: enrollmentId, channel: preference.channel, enabled, local_time: time, quiet_start: start, quiet_end: end, policy_version: preference.policy_version, expected_preference_id: preference.id, expected_lock_version: preference.lock_version } }) }}><fieldset disabled={disabled}><legend>{preference.channel === 'email' ? 'Optional generic email' : 'In-app daily prompt'}</legend><label className="privacy-check"><input type="checkbox" checked={enabled} onChange={(event) => setEnabled(event.target.checked)} />{preference.channel === 'email' ? 'I consent to a generic daily email reminder' : 'Enable in-app reminders'}</label><div className="privacy-time-grid"><label className="privacy-field">Local reminder time<input required type="time" value={time} onChange={(event) => setTime(event.target.value)} /></label><label className="privacy-field">Quiet hours begin<input required type="time" value={start} onChange={(event) => setStart(event.target.value)} /></label><label className="privacy-field">Quiet hours end<input required type="time" value={end} onChange={(event) => setEnd(event.target.value)} /></label></div><button type="submit">Review {preference.channel === 'email' ? 'email' : 'in-app'} preference</button></fieldset></form>
}
