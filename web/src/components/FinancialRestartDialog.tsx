import { useEffect, useRef, useState } from 'react'
import { ApiRequestError, applyFinancialRestart, cancelFinancialRestart, fetchFinancialRestartStatus, previewFinancialRestart, type FinancialRestartState } from '../api'
import { usePilotDialog } from '../lib/usePilotDialog'
import { applySetupRestart, cancelSetupRestart, fetchSetupRestartStatus, previewSetupRestart } from '../setupHelpApi'
import './FinancialRestartDialog.css'

const countLabels: Record<string, string> = {
  income_sources: 'Income sources', income_schedule_entries: 'Income changes and schedules',
  expense_items: 'Recurring expenses', budget_years: 'Annual plans', budget_categories: 'Spending categories',
  budget_allocations: 'Planned category amounts', debts: 'Household debts', accounts: 'Accounts and assets',
  goals: 'Household goals', transactions: 'Recorded transactions', transaction_drafts: 'Unreviewed transactions',
  mia_reviews: 'Pending Mia reviews', household_transactions: 'Recorded transactions',
  mia_action_drafts: 'Mia review records', merchant_category_rules: 'Saved merchant categories',
  document_imports: 'Document reviews', plaid_items: 'Bank connections',
  bank_connections: 'Bank connections', transaction_splits: 'Transaction splits',
  transaction_draft_splits: 'Unreviewed transaction splits',
}

export function FinancialRestartDialog({ scopeKey, blockedReason, onClose, onApplied, setupHelp, onReturnToSetupHelp }: {
  scopeKey: string; blockedReason?: string | null; onClose: () => void;
  onApplied: (generation: number) => void;
  setupHelp?: { requestId?: number };
  onReturnToSetupHelp?: (requestId?: number, reviewId?: number) => void;
}) {
  const [state, setState] = useState<FinancialRestartState | null>(null)
  const [phase, setPhase] = useState<'loading' | 'ready' | 'applying' | 'checking' | 'canceling'>(blockedReason ? 'ready' : 'loading')
  const [error, setError] = useState<string | null>(null)
  const [uncertain, setUncertain] = useState(false)
  const [confirmed, setConfirmed] = useState(false)
  const [sharedConfirmed, setSharedConfirmed] = useState(false)
  const [stale, setStale] = useState(false)
  const mounted = useRef(false)
  const request = useRef(0)
  const applied = useRef(false)
  const storageKey = `household-cfo:financial-restart:${scopeKey}${setupHelp ? `:setup:${setupHelp.requestId ?? 'self'}` : ''}`
  const title = setupHelp ? setupHelp.requestId ? 'Review prepared restart' : 'Start setup again' : 'Reset my test workspace'
  const unavailable = Boolean(setupHelp && state && !state.available)
  const readStatus = (id?: number) => setupHelp ? fetchSetupRestartStatus(id, setupHelp.requestId) : fetchFinancialRestartStatus(id)
  const prepareReview = () => setupHelp ? previewSetupRestart(setupHelp.requestId) : previewFinancialRestart()
  const busy = phase !== 'ready'
  const review = state?.review

  function clearRecovery() { try { window.sessionStorage.removeItem(storageKey) } catch { /* No sensitive data is stored. */ } }
  function finish(result: FinancialRestartState) {
    const receipt = result.review ?? result.latest_review
    const resultGeneration = result.result_generation ?? receipt?.result_generation
    const generation = resultGeneration == null ? null : Math.max(result.financial_generation, resultGeneration)
    if (receipt?.status !== 'applied' || !Number.isSafeInteger(generation) || generation == null) return false
    applied.current = true
    clearRecovery()
    onApplied(generation)
    return true
  }

  async function loadPreview() {
    const id = ++request.current
    setPhase('loading'); setError(null); setConfirmed(false); setSharedConfirmed(false); setStale(false)
    try {
      let recoveryId: number | null = null
      try { const value = Number(window.sessionStorage.getItem(storageKey)); if (Number.isSafeInteger(value) && value > 0) recoveryId = value } catch { /* Apply checks storage before writing. */ }
      const status = await readStatus(recoveryId ?? undefined)
      if (!mounted.current || id !== request.current) return
      if (recoveryId && finish(status)) return
      if (!status.available) { setState(status); return }
      if (recoveryId && status.review?.id === recoveryId && status.review.status === 'pending') {
        setState(status); setUncertain(true); return
      }
      clearRecovery()
      const preview = await prepareReview()
      if (!mounted.current || id !== request.current) return
      setState({ ...status, ...preview, household_name: preview.household_name ?? status.household_name }); setUncertain(false)
    } catch (caught) {
      if (mounted.current && id === request.current) {
        setError(caught instanceof Error ? caught.message : 'Your restart review could not be loaded.')
        if (setupHelp && caught instanceof ApiRequestError && [403, 404, 409, 422].includes(caught.status ?? 0)) setStale(true)
      }
    } finally { if (mounted.current && id === request.current) setPhase('ready') }
  }

  async function checkStatus() {
    if (!review || busy) return
    setPhase('checking'); setError(null)
    try {
      const result = await readStatus(review.id)
      if (!mounted.current || finish(result)) return
      setState(result); setUncertain(false)
      if (result.review?.status !== 'pending') { setStale(true); clearRecovery() }
    } catch (caught) {
      if (mounted.current) setError(caught instanceof Error ? caught.message : 'The restart status could not be checked.')
    } finally { if (mounted.current) setPhase('ready') }
  }

  async function apply() {
    if (!review || busy || stale || uncertain || !confirmed || unavailable || (review.shared_member_count > 0 && !sharedConfirmed)) return
    try {
      window.sessionStorage.setItem(storageKey, String(review.id))
      if (window.sessionStorage.getItem(storageKey) !== String(review.id)) throw new Error('Request recovery is unavailable.')
    } catch {
      setError('This browser cannot keep the request reference for safe recovery. Allow session storage or use another browser before starting over.'); return
    }
    setPhase('applying'); setError(null)
    try {
      const result = await (setupHelp ? applySetupRestart(review.id, sharedConfirmed, setupHelp.requestId) : applyFinancialRestart(review.id, sharedConfirmed))
      if (!mounted.current) return
      if (!finish(result)) { setUncertain(true); setError('The server did not confirm that start over finished. Check its status before trying again.') }
    } catch (caught) {
      if (!mounted.current) return
      if (caught instanceof ApiRequestError && (['financial_restart_review_stale', 'financial_restart_review_expired', 'financial_generation_stale', 'setup_help_stale'].includes(caught.code ?? '') || Boolean(setupHelp && [403, 404, 422].includes(caught.status ?? 0)))) {
        setStale(true); setConfirmed(false); clearRecovery()
      } else setUncertain(true)
      setError(caught instanceof Error ? caught.message : 'Start over was not confirmed. Check its status before trying again.')
    } finally { if (mounted.current) setPhase('ready') }
  }

  async function close(cancelSupportedRequest = false) {
    if (busy || applied.current) return
    if (uncertain || setupHelp?.requestId && !cancelSupportedRequest) { onClose(); return }
    if (!review || review.status !== 'pending' || stale) { onClose(); return }
    setPhase('canceling'); setError(null)
    try {
      const result = await (setupHelp ? cancelSetupRestart(review.id, setupHelp.requestId) : cancelFinancialRestart(review.id))
      if (!mounted.current || finish(result)) return
      clearRecovery(); onClose()
    } catch (caught) {
      if (mounted.current) setError(caught instanceof Error ? caught.message : 'Cancel was not confirmed. Check the review before closing.')
    } finally { if (mounted.current) setPhase('ready') }
  }
  const dialogRef = usePilotDialog(() => { void close() })
  useEffect(() => {
    mounted.current = true
    let active = true
    queueMicrotask(() => { if (active && !blockedReason) void loadPreview() })
    return () => { active = false; mounted.current = false; request.current += 1 }
    // Scope changes remount this dialog; a draft always belongs to its opening scope.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return <div className="pilot-dialog-overlay financial-restart-overlay" role="presentation">
    <section ref={dialogRef} className="pilot-dialog financial-restart-dialog" role="dialog" aria-modal="true" aria-labelledby="financial-restart-title" tabIndex={-1}>
      <header><div><p className="eyebrow">A fresh financial picture</p><h2 id="financial-restart-title">{title}</h2></div>
        <button type="button" className="secondary-button" disabled={busy} onClick={() => void close()}>Close</button></header>
      <div className="pilot-dialog-body">
        {blockedReason && <p role="status">{blockedReason}</p>}
        {!blockedReason && phase === 'loading' && <p role="status">Preparing your review. Your saved information stays as it is until you confirm.</p>}
        {error && <p className="document-alert" role="alert">{error}</p>}
        {!blockedReason && unavailable && <p>This setup or review needs another check. Return to Fix my setup to review corrections or request a fresh support review. Nothing changes from this screen.</p>}
        {!blockedReason && !setupHelp && state?.admin_required && <p>Resetting test data is available only to administrators in their own test workspace. Use Mia or My Money to review updates to individual records.</p>}
        {!blockedReason && !state?.admin_required && state?.owner_required && <p>Only the household owner can restart this shared financial picture. Ask the owner to review it with you. Your private chat and notes are separate.</p>}
        {!blockedReason && review && <>
          <p>Your active chat and financial picture will start fresh. Earlier records and conversations stay in private history, and setup returns to <strong>not entered</strong>.</p>
          {(review.household_name ?? state.household_name) && <p><strong>Household:</strong> {review.household_name ?? state.household_name}</p>}
          <h3>What starts fresh</h3>
          <dl className="financial-restart-counts">{Object.entries(review.counts).filter(([, count]) => !setupHelp || count > 0).map(([key, count]) => <div key={key}><dt>{countLabels[key] ?? key.replaceAll('_', ' ')}</dt><dd>{count}</dd></div>)}</dl>
          {setupHelp && Object.values(review.counts).some(count => count === 0) && <details className="financial-restart-empty"><summary>View empty record types</summary><dl className="financial-restart-counts">{Object.entries(review.counts).filter(([, count]) => count === 0).map(([key, count]) => <div key={key}><dt>{countLabels[key] ?? key.replaceAll('_', ' ')}</dt><dd>{count}</dd></div>)}</dl></details>}
          <p>Your money setup answers, household goal and financial profile will need to be entered again.</p>
          <h3>What stays</h3><ul>{review.preserved.map(value => <li key={value}>{value}</li>)}</ul>
          <h3>What needs a fresh review</h3><ul>{review.paused.map(value => <li key={value}>{value}</li>)}</ul>
          <p>Earlier household chat context and saved notes will not supply old practice numbers to your new starting picture. This flow does not delete your account or forget private notes.</p>
          <p className="financial-restart-expiry">Review valid until {new Date(review.expires_at).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}. Changes made elsewhere require a new review.</p>
          {!uncertain && !stale && !unavailable && review.status === 'pending' && <fieldset disabled={busy}>
            <label className="financial-restart-confirm"><input type="checkbox" checked={confirmed} onChange={event => setConfirmed(event.target.checked)} />I reviewed what starts fresh and what stays. {title}.</label>
            {review.shared_member_count > 0 && <label className="financial-restart-confirm"><input type="checkbox" checked={sharedConfirmed} onChange={event => setSharedConfirmed(event.target.checked)} />I understand this changes the shared financial picture for {review.shared_member_count} other household {review.shared_member_count === 1 ? 'member' : 'members'}, including their active conversation context. Earlier chats remain private history.</label>}
          </fieldset>}
        </>}
      </div>
      <footer className="financial-restart-actions">
        {setupHelp && (unavailable || stale) ? <button type="button" className="button button--primary" disabled={busy} onClick={() => onReturnToSetupHelp?.(setupHelp.requestId, review?.id ?? state?.latest_review?.id)}>Return to Fix my setup</button> : uncertain ? <button type="button" className="button button--primary" disabled={busy} onClick={() => void checkStatus()}>{phase === 'checking' ? 'Checking status…' : 'Check whether start over finished'}</button>
          : !blockedReason && (stale || (!review && !state?.owner_required && !state?.admin_required && phase === 'ready')) ? <button type="button" className="button button--primary" disabled={busy} onClick={() => void loadPreview()}>Prepare a fresh review</button>
          : review && <button type="button" className="button button--primary" disabled={busy || !confirmed || (review.shared_member_count > 0 && !sharedConfirmed)} onClick={() => void apply()}>{phase === 'applying' ? 'Starting over…' : title}</button>}
        <button type="button" className="secondary-button" disabled={busy} onClick={() => void close(true)}>{phase === 'canceling' ? 'Canceling…' : uncertain ? 'Close and check later' : setupHelp?.requestId ? 'Cancel restart request' : 'Keep my current picture'}</button>
      </footer>
    </section>
  </div>
}
