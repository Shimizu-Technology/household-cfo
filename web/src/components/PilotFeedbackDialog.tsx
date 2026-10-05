import { useEffect, useRef, useState, type FormEvent } from 'react'
import { fetchMyPilotFeedback, withdrawPilotFeedbackSupport, type PilotFeedbackInput, type PilotFeedbackReceipt, type PilotFeedbackWorkflow } from '../api'
import { useBrand } from '../contexts/brandContextValue'
import { usePilotDialog } from '../lib/usePilotDialog'
import { captureAnalyticsEvent, trackPilotWorkflowFailure } from '../lib/analytics'
import './PilotFeedbackDialog.css'

const pilotFeedbackOptions: Array<{ value: PilotFeedbackWorkflow; label: string }> = [
  { value: 'sign_in', label: 'Sign in or invitation' },
  { value: 'home', label: 'Home or next action' },
  { value: 'setup', label: 'Household setup' },
  { value: 'ask_mia', label: 'Assistant chat' },
  { value: 'voice', label: 'Voice entry' },
  { value: 'budget', label: 'Budget or annual plan' },
  { value: 'transaction_review', label: 'Transaction review' },
  { value: 'receipt_upload', label: 'Receipt upload' },
  { value: 'statement_upload', label: 'Statement upload' },
  { value: 'document_upload', label: 'Other document upload' },
  { value: 'private_document', label: 'Preview, download, or delete' },
  { value: 'admin', label: 'Cohort administration' },
  { value: 'other', label: 'Something else' },
]


export function PilotFeedbackDialog({
  initialWorkflow,
  onClose,
  onSubmit,
}: {
  initialWorkflow: PilotFeedbackWorkflow
  onClose: () => void
  onSubmit: (values: PilotFeedbackInput) => Promise<PilotFeedbackReceipt>
}) {
  const { brand, assistantName } = useBrand()
  const dialogRef = usePilotDialog(onClose)
  const [workflow, setWorkflow] = useState<PilotFeedbackWorkflow>(initialWorkflow)
  const [attempted, setAttempted] = useState('')
  const [expected, setExpected] = useState('')
  const [actual, setActual] = useState('')
  const [screenshot, setScreenshot] = useState<File | null>(null)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [receipt, setReceipt] = useState<PilotFeedbackReceipt | null>(null)
  const [shareWithSupport, setShareWithSupport] = useState(false)
  const [reports, setReports] = useState<PilotFeedbackReceipt[]>([])
  const [historyOpen, setHistoryOpen] = useState(false)
  const [cursor, setCursor] = useState<number | null>(null)
  const [historyLoading, setHistoryLoading] = useState(false)
  const [historyError, setHistoryError] = useState<string | null>(null)
  const [withdrawingId, setWithdrawingId] = useState<number | null>(null)
  const generation = useRef(0)
  const historyRequest = useRef<AbortController | null>(null)
  useEffect(() => { const mountedGeneration = ++generation.current; return () => { generation.current = mountedGeneration + 1; historyRequest.current?.abort() } }, [])

  async function loadReports(next?: number) {
    const current = generation.current
    historyRequest.current?.abort()
    const request = new AbortController()
    historyRequest.current = request
    setHistoryLoading(true); setHistoryError(null)
    try {
      const page = await fetchMyPilotFeedback(next, request.signal)
      if (current !== generation.current || request.signal.aborted) return
      setReports(previous => next ? [...previous, ...page.feedback_reports.filter(row => !previous.some(existing => existing.id === row.id))] : page.feedback_reports)
      setCursor(page.next_cursor)
    } catch (caught) {
      if (current === generation.current && !request.signal.aborted) setHistoryError(caught instanceof Error ? caught.message : 'Reports could not be loaded.')
    } finally {
      if (current === generation.current && !request.signal.aborted) setHistoryLoading(false)
    }
  }

  async function withdraw(id: number) {
    const current = generation.current
    historyRequest.current?.abort(); setHistoryLoading(false)
    setWithdrawingId(id); setError(null)
    try {
      const updated = await withdrawPilotFeedbackSupport(id)
      if (current !== generation.current) return
      setReceipt(previous => previous?.id === updated.id ? updated : previous)
      setReports(previous => previous.map(row => row.id === updated.id ? updated : row))
    } catch (caught) {
      if (current === generation.current) setError(caught instanceof Error ? caught.message : 'Withdrawal was not confirmed. Retry to check and withdraw access.')
    } finally {
      if (current === generation.current) setWithdrawingId(null)
    }
  }

  function supportAccess(report: PilotFeedbackReceipt) {
    return <div className="pilot-feedback-access">
      <p>{report.support_access_available ? 'App support can read this report and its optional screenshot.' : 'App support access is withdrawn or was not granted.'}</p>
      {report.support_access_available && <button type="button" className="secondary-button" disabled={withdrawingId !== null} onClick={() => void withdraw(report.id)}>{withdrawingId === report.id ? 'Withdrawing access' : `Withdraw support access to report #${report.id}`}</button>}
    </div>
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!attempted.trim() || !expected.trim() || !actual.trim()) {
      setError('Describe what you attempted, what you expected, and what happened.')
      return
    }
    if (screenshot && screenshot.size > 5 * 1024 * 1024) {
      setError('Screenshot must be 5 MB or smaller.')
      return
    }

    if (!shareWithSupport) { setError('Approve sharing this technical report with app support before submitting.'); return }
    const current = generation.current
    setSaving(true)
    setError(null)
    try {
      const receipt = await onSubmit({ workflow, attempted: attempted.trim(), expected: expected.trim(), actual: actual.trim(), screenshot, share_with_support: true })
      if (current !== generation.current) return
      captureAnalyticsEvent('pilot_feedback_report_submitted', { workflow, screenshot_attached: receipt.screenshot_attached })
      setReceipt(receipt)
    } catch (caught) {
      if (current !== generation.current) return
      trackPilotWorkflowFailure('feedback', 'submit', { workflow })
      setError(caught instanceof Error ? caught.message : 'Feedback could not be submitted. Please try again.')
    } finally {
      if (current === generation.current) setSaving(false)
    }
  }

  return (
    <div className="pilot-dialog-overlay" role="presentation">
      <button type="button" className="pilot-dialog-backdrop" aria-label="Close feedback form" onClick={onClose} />
      <section ref={dialogRef} className="pilot-dialog pilot-feedback-dialog" role="dialog" aria-modal="true" aria-labelledby="pilot-feedback-title" tabIndex={-1}>
        <header>
          <div><p className="eyebrow">Pilot support</p><h2 id="pilot-feedback-title">Report what got in your way.</h2></div>
          <button type="button" className="secondary-button" onClick={onClose}>Close</button>
        </header>
        {receipt ? (
          <div className="pilot-feedback-success" role="status">
            <strong>Report received.</strong>
            <p>Reference #{receipt.id}. Your written details and optional screenshot were not sent to analytics.</p>
            {supportAccess(receipt)}
            <button type="button" onClick={onClose}>Return to {brand.product_name}</button>
          </div>
        ) : (
          <form onSubmit={handleSubmit}>
            <p className="pilot-privacy-note">Do not include account numbers, exact financial values, document contents, passwords, or private {assistantName} messages. Crop screenshots to the problem area.</p>
            <label><span>Screen or workflow</span><select value={workflow} onChange={(event) => setWorkflow(event.currentTarget.value as PilotFeedbackWorkflow)}>{pilotFeedbackOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</select></label>
            <label><span>What did you attempt?</span><textarea rows={3} maxLength={2000} value={attempted} onChange={(event) => setAttempted(event.currentTarget.value)} /></label>
            <label><span>What did you expect?</span><textarea rows={3} maxLength={2000} value={expected} onChange={(event) => setExpected(event.currentTarget.value)} /></label>
            <label><span>What happened instead?</span><textarea rows={3} maxLength={2000} value={actual} onChange={(event) => setActual(event.currentTarget.value)} /></label>
            <label className="pilot-screenshot-field"><span>Optional cropped screenshot</span><input type="file" accept=".jpg,.jpeg,.png,.webp,image/jpeg,image/png,image/webp" onChange={(event) => setScreenshot(event.currentTarget.files?.[0] ?? null)} /><small>{screenshot ? `${screenshot.name} · ${Math.ceil(screenshot.size / 1024)} KB` : 'JPG, PNG, or WebP · 5 MB maximum'}</small></label>
            <div className="pilot-feedback-consent">
              <p>App support administrators can read only this technical report and its optional screenshot. This does not grant access to your statements, savings records, feelings, or private {assistantName} chat.</p>
              <label><input type="checkbox" checked={shareWithSupport} onChange={event => setShareWithSupport(event.currentTarget.checked)} /><span>I agree to share this report and optional screenshot with app support administrators.</span></label>
            </div>
            <button type="submit" disabled={saving || !shareWithSupport}>{saving ? 'Submitting report' : 'Submit report'}</button>
          </form>
        )}
        {error && <p className="setup-error" role="alert">{error}</p>}
        <details className="pilot-feedback-history" open={historyOpen} onToggle={event => { const opened = event.currentTarget.open; setHistoryOpen(opened); if (opened && !historyOpen) void loadReports() }}>
          <summary>My submitted reports</summary>
          {historyLoading && <p role="status">Loading reports</p>}
          {historyError && <p role="alert">{historyError} <button type="button" onClick={() => void loadReports()}>Retry reports</button></p>}
          {!historyLoading && !historyError && reports.length === 0 && <p>No reports submitted.</p>}
          {reports.map(report => <article key={report.id}><strong>Report #{report.id}</strong><p>{pilotFeedbackOptions.find(option => option.value === report.workflow)?.label ?? report.workflow} · {report.status}</p>{supportAccess(report)}</article>)}
          {cursor && <button type="button" disabled={historyLoading} onClick={() => void loadReports(cursor)}>Load earlier reports</button>}
        </details>
        <p className="pilot-feedback-withdrawal-note">Withdrawing stops new support reads. It cannot recall details already read or downloaded. Previously issued screenshot links can remain valid for up to five minutes.</p>
      </section>
    </div>
  )
}

