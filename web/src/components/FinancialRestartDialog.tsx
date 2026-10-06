import { useEffect, useRef, useState } from 'react'
import { ApiRequestError, applyFinancialRestart, cancelFinancialRestart, fetchFinancialRestartStatus, previewFinancialRestart, type FinancialRestartState } from '../api'
import { usePilotDialog } from '../lib/usePilotDialog'
import './FinancialRestartDialog.css'

const countLabels: Record<string, string> = {
  income_sources: 'Income sources', income_schedule_entries: 'Income changes and schedules',
  expense_items: 'Recurring expenses', budget_years: 'Annual plans', budget_categories: 'Spending categories',
  budget_allocations: 'Planned category amounts', debts: 'Household debts', accounts: 'Accounts and assets',
  goals: 'Household goals', transactions: 'Recorded transactions', transaction_drafts: 'Unreviewed transactions',
  mia_reviews: 'Pending Mia reviews',
}

export function FinancialRestartDialog({ scopeKey, blockedReason, onClose, onApplied }: {
  scopeKey: string; blockedReason?: string | null; onClose: () => void;
  onApplied: (generation: number) => void;
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
  const storageKey = `household-cfo:financial-restart:${scopeKey}`
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
      const status = await fetchFinancialRestartStatus(recoveryId ?? undefined)
      if (!mounted.current || id !== request.current) return
      if (recoveryId && finish(status)) return
      if (!status.available) { setState(status); return }
      if (recoveryId && status.review?.id === recoveryId && status.review.status === 'pending') {
        setState(status); setUncertain(true); return
      }
      clearRecovery()
      const preview = await previewFinancialRestart()
      if (!mounted.current || id !== request.current) return
      setState(preview); setUncertain(false)
    } catch (caught) {
      if (mounted.current && id === request.current) setError(caught instanceof Error ? caught.message : 'Your restart review could not be loaded.')
    } finally { if (mounted.current && id === request.current) setPhase('ready') }
  }

  async function checkStatus() {
    if (!review || busy) return
    setPhase('checking'); setError(null)
    try {
      const result = await fetchFinancialRestartStatus(review.id)
      if (!mounted.current || finish(result)) return
      setState(result); setUncertain(false)
      if (result.review?.status !== 'pending') { setStale(true); clearRecovery() }
    } catch (caught) {
      if (mounted.current) setError(caught instanceof Error ? caught.message : 'The restart status could not be checked.')
    } finally { if (mounted.current) setPhase('ready') }
  }

  async function apply() {
    if (!review || busy || stale || uncertain || !confirmed || (review.shared_member_count > 0 && !sharedConfirmed)) return
    try {
      window.sessionStorage.setItem(storageKey, String(review.id))
      if (window.sessionStorage.getItem(storageKey) !== String(review.id)) throw new Error('Request recovery is unavailable.')
    } catch {
      setError('This browser cannot keep the request reference for safe recovery. Allow session storage or use another browser before starting over.'); return
    }
    setPhase('applying'); setError(null)
    try {
      const result = await applyFinancialRestart(review.id, sharedConfirmed)
      if (!mounted.current) return
      if (!finish(result)) { setUncertain(true); setError('The server did not confirm that start over finished. Check its status before trying again.') }
    } catch (caught) {
      if (!mounted.current) return
      if (caught instanceof ApiRequestError && ['financial_restart_review_stale', 'financial_restart_review_expired', 'financial_generation_stale'].includes(caught.code ?? '')) {
        setStale(true); setConfirmed(false); clearRecovery()
      } else setUncertain(true)
      setError(caught instanceof Error ? caught.message : 'Start over was not confirmed. Check its status before trying again.')
    } finally { if (mounted.current) setPhase('ready') }
  }

  async function close() {
    if (busy || applied.current) return
    if (uncertain) { onClose(); return }
    if (!review || review.status !== 'pending' || stale) { onClose(); return }
    setPhase('canceling'); setError(null)
    try {
      const result = await cancelFinancialRestart(review.id)
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
      <header><div><p className="eyebrow">A fresh financial picture</p><h2 id="financial-restart-title">Start over with my real numbers</h2></div>
        <button type="button" className="secondary-button" disabled={busy} onClick={() => void close()}>Close</button></header>
      <div className="pilot-dialog-body">
        {blockedReason && <p role="status">{blockedReason}</p>}
        {!blockedReason && phase === 'loading' && <p role="status">Preparing your review. Your saved information stays as it is until you confirm.</p>}
        {error && <p className="document-alert" role="alert">{error}</p>}
        {!blockedReason && state?.owner_required && <p>Only the household owner can restart this shared financial picture. Ask the owner to review it with you. Your private chat and notes are separate.</p>}
        {!blockedReason && review && <>
          <p>Your earlier financial history is retained. It will stop contributing to your new plan, and setup will return to <strong>not entered</strong>.</p>
          {state.household_name && <p><strong>Household:</strong> {state.household_name}</p>}
          <h3>What starts fresh</h3>
          <dl className="financial-restart-counts">{Object.entries(review.counts).map(([key, count]) => <div key={key}><dt>{countLabels[key] ?? key.replaceAll('_', ' ')}</dt><dd>{count}</dd></div>)}</dl>
          <p>Your money setup answers, household goal and financial profile will need to be entered again.</p>
          <h3>What stays</h3><ul>{review.preserved.map(value => <li key={value}>{value}</li>)}</ul>
          <h3>What needs a fresh review</h3><ul>{review.paused.map(value => <li key={value}>{value}</li>)}</ul>
          <p>Earlier household chat context and saved notes will not supply old practice numbers to your new starting picture. This flow does not delete your account or forget private notes.</p>
          <p className="financial-restart-expiry">Review valid until {new Date(review.expires_at).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}. Changes made elsewhere require a new review.</p>
          {!uncertain && !stale && review.status === 'pending' && <fieldset disabled={busy}>
            <label className="financial-restart-confirm"><input type="checkbox" checked={confirmed} onChange={event => setConfirmed(event.target.checked)} />I reviewed what starts fresh and what stays. Start over with my real numbers.</label>
            {review.shared_member_count > 0 && <label className="financial-restart-confirm"><input type="checkbox" checked={sharedConfirmed} onChange={event => setSharedConfirmed(event.target.checked)} />I understand this changes the shared financial picture for {review.shared_member_count} other household {review.shared_member_count === 1 ? 'member' : 'members'}.</label>}
          </fieldset>}
        </>}
      </div>
      <footer className="financial-restart-actions">
        {uncertain ? <button type="button" className="primary-button" disabled={busy} onClick={() => void checkStatus()}>{phase === 'checking' ? 'Checking status…' : 'Check whether start over finished'}</button>
          : !blockedReason && (stale || (!review && !state?.owner_required && phase === 'ready')) ? <button type="button" className="primary-button" disabled={busy} onClick={() => void loadPreview()}>Prepare a fresh review</button>
          : review && <button type="button" className="primary-button" disabled={busy || !confirmed || (review.shared_member_count > 0 && !sharedConfirmed)} onClick={() => void apply()}>{phase === 'applying' ? 'Starting over…' : 'Start over with my real numbers'}</button>}
        <button type="button" className="secondary-button" disabled={busy} onClick={() => void close()}>{phase === 'canceling' ? 'Canceling…' : uncertain ? 'Close and check later' : 'Keep my current picture'}</button>
      </footer>
    </section>
  </div>
}
