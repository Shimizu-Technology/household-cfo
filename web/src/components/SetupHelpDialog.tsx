import { useEffect, useRef, useState } from 'react'
import { changeOwnSetupSupportRequest, createSetupSupportRequest, fetchSetupHelp } from '../setupHelpApi'
import { activeSetupRequest, setupSupportReasons, setupSupportStatusLabel, type SetupHelpState, type SetupSupportReason } from '../lib/setupHelp'
import { moneyTopics, type MoneyTopic } from '../lib/moneyNavigation'
import { ApiRequestError } from '../api'
import { usePilotDialog } from '../lib/usePilotDialog'
import './SetupHelpDialog.css'

type Props = {
  scopeKey: string; userId: number; householdId: number; onClose: () => void
  onTopic: (topic: MoneyTopic) => boolean; onAskMia: () => boolean
  onRestart: (requestId?: number) => void; blockedReason?: string | null
  staleReview?: { requestId: number; reviewId?: number } | null
  onReviewReopened?: () => void
}

export function SetupHelpDialog(props: Props) {
  const dialog = usePilotDialog(props.onClose)
  const [state, setState] = useState<SetupHelpState | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [reason, setReason] = useState<SetupSupportReason>('practice_numbers')
  const [shared, setShared] = useState(false)
  const [uncertain, setUncertain] = useState(false)
  const [recoveringCreate, setRecoveringCreate] = useState(false)
  const [referenceRejected, setReferenceRejected] = useState(false)
  const [referenceStatusChecked, setReferenceStatusChecked] = useState(false)
  const mounted = useRef(true)
  const sequence = useRef(0)
  const abort = useRef<AbortController | null>(null)
  const requestKey = useRef<string | null>(null)
  const recoveryKey = `household-cfo:setup-support:${props.scopeKey}`
  const request = state?.latest_request ?? null
  const activeRequest = activeSetupRequest(request)
  const needsFreshReview = request?.status === 'ready' && (props.staleReview?.requestId === request.id && (props.staleReview.reviewId != null && props.staleReview.reviewId === request.review_id) || ['expired', 'stale', 'canceled'].includes(request.review_state))

  function acceptState(next: SetupHelpState) {
    if (!next || next.household_id !== props.householdId || typeof next.self_restart_available !== 'boolean'
      || next.latest_request && (next.latest_request.user_id !== props.userId || next.latest_request.household_id !== props.householdId || next.latest_request.cohort_id !== next.cohort_id)) {
      throw new Error('This setup response could not be verified for your account. Close it and reload your workspace.')
    }
    setState(next)
  }
  function clearReference() {
    requestKey.current = null
    try { window.sessionStorage.removeItem(recoveryKey) } catch { /* The server also keeps one active request in this scope. */ }
  }
  async function load() {
    abort.current?.abort()
    const controller = new AbortController(); abort.current = controller
    const id = ++sequence.current
    setLoading(true); setError(null)
    try {
      const next = await fetchSetupHelp(controller.signal)
      if (!mounted.current || id !== sequence.current) return
      acceptState(next)
      if (requestKey.current) setReferenceStatusChecked(true)
      if (activeSetupRequest(next.latest_request)) { clearReference(); setRecoveringCreate(false) }
      if (!requestKey.current) setUncertain(false)
    } catch (caught) {
      if (mounted.current && id === sequence.current) setError(caught instanceof Error ? caught.message : 'Setup help could not be loaded.')
    } finally { if (mounted.current && id === sequence.current) setLoading(false) }
  }
  useEffect(() => {
    mounted.current = true
    try {
      const stored = window.sessionStorage.getItem(recoveryKey)
      if (stored) {
        const saved = JSON.parse(stored) as { key: string; reason: SetupSupportReason }
        if (typeof saved.key === 'string' && setupSupportReasons.some(item => item.value === saved.reason)) {
          requestKey.current = saved.key
          queueMicrotask(() => { if (mounted.current) { setReason(saved.reason); setUncertain(true); setRecoveringCreate(true) } })
        }
      }
    } catch { /* A safe fresh request can still be made when no reference exists. */ }
    queueMicrotask(() => { if (mounted.current) void load() })
    return () => { mounted.current = false; sequence.current += 1; abort.current?.abort() }
    // Scope changes remount the dialog, including its recovery reference.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  async function sendRequest() {
    if (!state?.available || state.owner_required || busy || loading || !shared && !recoveringCreate) return
    setBusy(true); setError(null); setNotice(null)
    try {
      const key = requestKey.current ?? crypto.randomUUID()
      // Keep the same reference and reason if the reply is lost or the page reloads.
      try { window.sessionStorage.setItem(recoveryKey, JSON.stringify({ key, reason })) }
      catch {
        setError('Your browser cannot keep the recovery reference. No support request was sent this time. Enable session storage or try another browser, then retry.'); return
      }
      requestKey.current = key
      const result = await createSetupSupportRequest(reason, key)
      if (!mounted.current) return
      acceptState(result.setup_help); clearReference(); setUncertain(false); setRecoveringCreate(false); setShared(false)
      setNotice('Your request is saved. Your financial information and chat have not changed.')
    } catch (caught) {
      if (!mounted.current) return
      setUncertain(Boolean(requestKey.current)); setRecoveringCreate(Boolean(requestKey.current))
      if (caught instanceof ApiRequestError && [404, 409].includes(caught.status ?? 0)) { setReferenceRejected(true); setReferenceStatusChecked(false) }
      setError(caught instanceof Error ? caught.message : 'The request was not confirmed. Check its status before trying again.')
    } finally { if (mounted.current) setBusy(false) }
  }
  async function changeRequest(action: 'cancel' | 'reopen') {
    if (!request || busy || loading) return
    setBusy(true); setError(null); setNotice(null)
    try {
      const result = await changeOwnSetupSupportRequest(request.id, action, request.lock_version)
      if (!mounted.current) return
      acceptState(result.setup_help); setUncertain(false)
      if (action === 'reopen') props.onReviewReopened?.()
      setNotice(action === 'cancel' ? 'Your request is canceled. Your saved information stays as it is.' : 'A fresh support review has been requested. Nothing changed in your financial picture.')
    } catch (caught) {
      if (!mounted.current) return
      setError(caught instanceof Error ? caught.message : 'The request update was not confirmed. Refresh its status before trying again.')
      setUncertain(true)
    } finally { if (mounted.current) setBusy(false) }
  }
  function go(topic?: MoneyTopic) {
    const moved = topic ? props.onTopic(topic) : props.onAskMia()
    if (moved) props.onClose()
    else setError('That correction tool is not available right now. Finish any open edits, or ask Mia to help.')
  }
  return <div className="pilot-dialog-overlay" role="presentation"><section ref={dialog} className="pilot-dialog setup-help-dialog" role="dialog" aria-modal="true" aria-labelledby="setup-help-title" tabIndex={-1}>
    <header><div><p className="eyebrow">Your information, your review</p><h2 id="setup-help-title">Fix my setup</h2></div><button type="button" className="secondary-button" disabled={busy} onClick={props.onClose}>Close</button></header>
    <div className="pilot-dialog-body">
      <section className="setup-help-section"><h3>Correct something I entered</h3><p>Open the right record or ask Mia to prepare a correction. Check the change before applying it.</p>
        <div className="setup-help-topics">{moneyTopics.map(topic => <button type="button" className="secondary-button" key={topic.id} disabled={busy} onClick={() => go(topic.id)}>{topic.label}</button>)}</div>
        <button type="button" className="button button--primary" disabled={busy} onClick={() => go()}>Talk through a correction with Mia</button>
      </section>
      {error && <p role="alert" className="document-alert">{error}</p>}
      {notice && <p role="status">{notice}</p>}
      {loading && <p role="status">Checking your setup and saved records…</p>}
      <section className="setup-help-section"><h3>Start setup again</h3>
        <p>A reviewed restart opens a fresh financial picture and active chat. Earlier records and conversations remain as history. BOG enrollment, approved savings, evidence and challenge history stay in place.</p>
        {props.blockedReason && <p role="status">{props.blockedReason}</p>}
        {state?.owner_required && <p>The household owner needs to review a restart of shared setup. You can still correct individual records above.</p>}
        {state?.self_restart_available && !activeRequest && <><p>Your unfinished setup has no saved financial facts or approved challenge activity to invalidate. Review the exact scope before starting again.</p><button type="button" className="secondary-button" disabled={busy || loading || Boolean(props.blockedReason)} onClick={() => props.onRestart()}>Review starting setup again</button></>}
        {state && !state.self_restart_available && !state.owner_required && <><p>Saved records or approved activity need a support review before a full restart. You can correct individual records now.</p><ul>{state.blockers.map(blocker => <li key={blocker.code}>{blocker.label}</li>)}</ul></>}
      </section>
      {request && <section className="setup-help-section" aria-label="Your setup support request"><h3>{needsFreshReview ? 'Review needs refreshing' : setupSupportStatusLabel(request.status)}</h3><p>Request #{request.id} · {request.reason_label}</p>
        {request.status === 'ready' && !needsFreshReview && <><p>Support prepared an exact review. Your information stays unchanged until you review and confirm it.</p><button type="button" className="button button--primary" disabled={busy || loading || uncertain || Boolean(props.blockedReason)} onClick={() => props.onRestart(request.id)}>Review prepared restart</button></>}
        {needsFreshReview && <><p>This review needs to be prepared again. You can request a fresh review without changing your numbers.</p><button type="button" className="secondary-button" disabled={busy || loading || uncertain} onClick={() => void changeRequest('reopen')}>Request a fresh review</button></>}
        {['requested', 'in_review'].includes(request.status) && <p>Your support team can review this request. You will confirm the exact scope before any restart.</p>}
        <div className="setup-help-actions"><button type="button" className="secondary-button" disabled={busy || loading} onClick={() => void load()}>Refresh request status</button>{activeRequest && <button type="button" className="secondary-button" disabled={busy || loading || uncertain} onClick={() => void changeRequest('cancel')}>Cancel request</button>}</div>
      </section>}
      {state?.available && !state.owner_required && !activeRequest && !state.self_restart_available && <section className="setup-help-section"><h3>Ask for a reviewed restart</h3><p>Share only your request reason and status with your program’s support team, or platform support when no program is assigned. This does not share financial values, documents, private chat or memories.</p>
        <label>What needs help?<select aria-label="What needs help?" value={reason} disabled={busy || loading || recoveringCreate} onChange={event => { setReason(event.target.value as SetupSupportReason); setShared(false) }}>{setupSupportReasons.map(item => <option value={item.value} key={item.value}>{item.label}</option>)}</select></label>
        <label className="setup-help-consent"><input type="checkbox" checked={shared} disabled={busy || loading || recoveringCreate} onChange={event => setShared(event.target.checked)} />Share this request’s reason and status with support. I will review any proposed restart before it happens.</label>
        <button type="button" className="button button--primary" disabled={busy || loading || !shared && !recoveringCreate} onClick={() => void sendRequest()}>{busy ? 'Saving request…' : recoveringCreate ? 'Retry the same request' : 'Request support review'}</button>
      </section>}
      {referenceRejected && referenceStatusChecked && state?.available && !activeRequest && <section className="setup-help-section"><p>The earlier request reference is no longer usable in this program access. Its old review cannot be applied here. Start a new request with fresh sharing confirmation.</p><button type="button" className="secondary-button" disabled={busy || loading} onClick={() => { clearReference(); setRecoveringCreate(false); setUncertain(false); setReferenceRejected(false); setReferenceStatusChecked(false); setShared(false); setError(null) }}>Start a new support request</button></section>}
      {uncertain && <section className="setup-help-section"><p>The last request has not been confirmed. Check its saved status before making another change.</p><button type="button" className="secondary-button" disabled={busy || loading} onClick={() => void load()}>Check request status</button></section>}
      {state === null && !loading && <button type="button" className="secondary-button" onClick={() => void load()}>Try again</button>}
    </div>
  </section></div>
}
