import { useCallback, useEffect, useState } from 'react'
import {
  fetchAdminPilotFeedback,
  fetchAdminPilotFeedbackReport,
  fetchAdminPilotFeedbackScreenshotUrl,
  updateAdminPilotFeedbackStatus,
  type AdminPilotFeedbackCounts,
  type AdminPilotFeedbackDetail,
  type AdminPilotFeedbackScreenshotUrl,
  type AdminPilotFeedbackSummary,
  type PilotFeedbackStatus,
  type PilotFeedbackWorkflow,
} from '../api'
import './PilotFeedbackInbox.css'

type FeedbackFilter = PilotFeedbackStatus | 'all'

const filters: Array<{ value: FeedbackFilter; label: string }> = [
  { value: 'submitted', label: 'New' },
  { value: 'reviewed', label: 'Reviewed' },
  { value: 'resolved', label: 'Resolved' },
  { value: 'all', label: 'All' },
]

const workflowLabels: Record<PilotFeedbackWorkflow, string> = {
  sign_in: 'Sign in',
  home: 'Home',
  setup: 'Setup',
  ask_mia: 'Ask Mia',
  voice: 'Voice',
  budget: 'Budget',
  transaction_review: 'Transaction review',
  receipt_upload: 'Receipt upload',
  statement_upload: 'Statement upload',
  document_upload: 'Document upload',
  private_document: 'Private document',
  admin: 'Admin',
  other: 'Other',
}

const emptyCounts: AdminPilotFeedbackCounts = { submitted: 0, reviewed: 0, resolved: 0 }

export function PilotFeedbackInbox() {
  const [filter, setFilter] = useState<FeedbackFilter>('submitted')
  const [reports, setReports] = useState<AdminPilotFeedbackSummary[]>([])
  const [counts, setCounts] = useState<AdminPilotFeedbackCounts>(emptyCounts)
  const [selectedId, setSelectedId] = useState<number | null>(null)
  const [detail, setDetail] = useState<AdminPilotFeedbackDetail | null>(null)
  const [screenshotLink, setScreenshotLink] = useState<AdminPilotFeedbackScreenshotUrl | null>(null)
  const [loading, setLoading] = useState(true)
  const [detailLoading, setDetailLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [screenshotLoading, setScreenshotLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)

  const loadDetail = useCallback(async (reportId: number) => {
    setDetailLoading(true)
    setScreenshotLink(null)
    try {
      const nextDetail = await fetchAdminPilotFeedbackReport(reportId)
      setDetail(nextDetail)
    } catch (caught) {
      setDetail(null)
      setError(caught instanceof Error ? caught.message : 'Feedback detail could not be loaded.')
    } finally {
      setDetailLoading(false)
    }
  }, [])

  const loadReports = useCallback(async (status: FeedbackFilter, preferredId?: number | null) => {
    setLoading(true)
    setError(null)
    try {
      const response = await fetchAdminPilotFeedback(status)
      const nextSelectedId = preferredId && response.feedback_reports.some((report) => report.id === preferredId)
        ? preferredId
        : response.feedback_reports[0]?.id ?? null

      setReports(response.feedback_reports)
      setCounts(response.counts)
      setSelectedId(nextSelectedId)
      if (nextSelectedId) await loadDetail(nextSelectedId)
      else {
        setDetail(null)
        setScreenshotLink(null)
      }
    } catch (caught) {
      setReports([])
      setDetail(null)
      setError(caught instanceof Error ? caught.message : 'Pilot feedback could not be loaded.')
    } finally {
      setLoading(false)
    }
  }, [loadDetail])

  useEffect(() => {
    let cancelled = false

    queueMicrotask(() => {
      if (!cancelled) void loadReports(filter)
    })

    return () => {
      cancelled = true
    }
  }, [filter, loadReports])

  async function selectReport(reportId: number) {
    if (reportId === selectedId && detail) return
    setSelectedId(reportId)
    setError(null)
    setNotice(null)
    await loadDetail(reportId)
  }

  async function changeStatus(status: PilotFeedbackStatus) {
    if (!detail || detail.status === status || saving) return

    setSaving(true)
    setError(null)
    setNotice(null)
    try {
      const updated = await updateAdminPilotFeedbackStatus(detail.id, status)
      setDetail(updated)
      setNotice(`Feedback marked ${status}.`)
      await loadReports(filter, updated.id)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Feedback status could not be saved.')
    } finally {
      setSaving(false)
    }
  }

  async function prepareScreenshot() {
    if (!detail?.screenshot || screenshotLoading) return

    setScreenshotLoading(true)
    setError(null)
    setScreenshotLink(null)
    try {
      setScreenshotLink(await fetchAdminPilotFeedbackScreenshotUrl(detail.id))
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'The private screenshot link could not be prepared.')
    } finally {
      setScreenshotLoading(false)
    }
  }

  const totalCount = counts.submitted + counts.reviewed + counts.resolved

  return (
    <article className="panel admin-card pilot-feedback-inbox" aria-labelledby="pilot-feedback-title">
      <div className="admin-card-heading row-between pilot-feedback-heading">
        <div className="pilot-feedback-title-group">
          <span className="pilot-feedback-icon" aria-hidden="true"><FeedbackIcon /></span>
          <div>
            <p className="eyebrow">Private pilot feedback</p>
            <h3 id="pilot-feedback-title">Review what testers reported</h3>
            <p>Only admins can read these narratives or prepare five-minute screenshot links.</p>
          </div>
        </div>
        <button type="button" className="admin-refresh" onClick={() => void loadReports(filter, selectedId)} disabled={loading}>
          {loading ? 'Refreshing' : 'Refresh feedback'}
        </button>
      </div>

      {error && <p className="admin-alert error" role="alert">{error}</p>}
      {notice && <p className="admin-alert success" aria-live="polite">{notice}</p>}

      <div className="pilot-feedback-filters" aria-label="Filter pilot feedback by status">
        {filters.map((option) => {
          const count = option.value === 'all' ? totalCount : counts[option.value]
          return (
            <button
              type="button"
              key={option.value}
              aria-pressed={filter === option.value}
              onClick={() => {
                setNotice(null)
                setFilter(option.value)
              }}
            >
              <span>{option.label}</span>
              <strong>{count}</strong>
            </button>
          )
        })}
      </div>

      <div className="pilot-feedback-layout">
        <div className="pilot-feedback-list" aria-label="Pilot feedback reports">
          {loading && reports.length === 0 ? (
            <p className="admin-muted">Loading private feedback...</p>
          ) : reports.length === 0 ? (
            <p className="pilot-feedback-empty">No {filter === 'all' ? '' : `${filter} `}feedback reports.</p>
          ) : reports.map((report) => (
            <button
              type="button"
              className={selectedId === report.id ? 'active' : ''}
              aria-current={selectedId === report.id ? 'true' : undefined}
              key={report.id}
              onClick={() => void selectReport(report.id)}
            >
              <span className="pilot-feedback-list-topline">
                <strong>{workflowLabels[report.workflow]}</strong>
                <StatusLabel status={report.status} />
              </span>
              <span>{report.reporter.full_name || report.reporter.email}</span>
              <small>{formatFeedbackDate(report.created_at)}{report.screenshot_attached ? ' · Screenshot attached' : ''}</small>
            </button>
          ))}
        </div>

        <section className="pilot-feedback-detail" aria-live="polite" aria-busy={detailLoading}>
          {detailLoading ? (
            <p className="admin-muted">Loading the selected report...</p>
          ) : detail ? (
            <>
              <header>
                <div>
                  <span>{workflowLabels[detail.workflow]}</span>
                  <h4>{detail.reporter.full_name || 'Pilot participant'}</h4>
                  <a href={`mailto:${detail.reporter.email}`}>{detail.reporter.email}</a>
                </div>
                <StatusLabel status={detail.status} />
              </header>

              <dl className="pilot-feedback-narrative">
                <div><dt>What they tried</dt><dd>{detail.attempted}</dd></div>
                <div><dt>What they expected</dt><dd>{detail.expected}</dd></div>
                <div><dt>What happened</dt><dd>{detail.actual}</dd></div>
              </dl>

              {detail.screenshot && (
                <div className="pilot-feedback-screenshot">
                  <div>
                    <strong>{detail.screenshot.filename}</strong>
                    <span>{formatBytes(detail.screenshot.byte_size)} · private attachment</span>
                  </div>
                  {screenshotLink ? (
                    <div className="pilot-feedback-link-actions">
                      <a href={screenshotLink.url} target="_blank" rel="noreferrer">Open screenshot</a>
                      <a href={screenshotLink.download_url}>Download</a>
                      <small>Links expire in {Math.round(screenshotLink.expires_in / 60)} minutes.</small>
                    </div>
                  ) : (
                    <button type="button" onClick={() => void prepareScreenshot()} disabled={screenshotLoading}>
                      {screenshotLoading ? 'Preparing link' : 'Prepare private link'}
                    </button>
                  )}
                </div>
              )}

              <div className="pilot-feedback-status-actions" aria-label="Feedback review status">
                <span>Review status</span>
                <div>
                  {(['submitted', 'reviewed', 'resolved'] as PilotFeedbackStatus[]).map((status) => (
                    <button
                      type="button"
                      key={status}
                      aria-pressed={detail.status === status}
                      disabled={saving || detail.status === status}
                      onClick={() => void changeStatus(status)}
                    >
                      {status === 'submitted' ? 'Reopen' : status === 'reviewed' ? 'Mark reviewed' : 'Mark resolved'}
                    </button>
                  ))}
                </div>
              </div>
            </>
          ) : (
            <p className="pilot-feedback-empty">Select a report to review the private details.</p>
          )}
        </section>
      </div>
    </article>
  )
}

function StatusLabel({ status }: { status: PilotFeedbackStatus }) {
  return <span className={`pilot-feedback-status ${status}`}>{status === 'submitted' ? 'New' : status}</span>
}

function formatFeedbackDate(value: string) {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return new Intl.DateTimeFormat('en-US', { dateStyle: 'medium', timeStyle: 'short' }).format(date)
}

function formatBytes(bytes: number) {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`
}

function FeedbackIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path d="M5.5 5.5h13v9h-7l-4.5 4v-4H5.5z" stroke="currentColor" strokeWidth="1.7" strokeLinejoin="round" />
      <path d="M8.5 9h7M8.5 12h4" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" />
    </svg>
  )
}
