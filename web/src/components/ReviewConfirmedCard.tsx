import type { ReactNode } from 'react'
import type { SpendingReport } from '../api'
import { formatReviewMoney } from '../lib/reviewMoney'

/** Read the report total, never the length of its capped transaction list. */
export function ReviewConfirmedCard({ report, loading, error, children }: { report: SpendingReport | null; loading: boolean; error: string | null; children: ReactNode }) {
  return <section className="review-confirmed ui-card" aria-label="Confirmed spending this month">
    <h3 className="ui-section">Confirmed this month</h3>
    {report && <p className="ui-label">{report.period_label}</p>}
    <p className="review-confirmed-total">{loading ? 'Loading report' : !report || error ? 'Not known yet' : formatReviewMoney(Math.round(report.totals.actual * 100))}</p>
    {error && <p role="alert" className="setup-error">{error}</p>}
    <details key={`${report?.start_on}:${report?.end_on}`} className="review-confirmed-list"><summary>See all</summary>
      {children}
      {report && report.transactions.length === 0 && (report.ignored_drafts?.length ?? 0) === 0 && <p>{report.totals.actual === 0 ? 'No confirmed transactions for this period yet.' : 'Confirmed purchases aren’t available in this report.'}</p>}
    </details>
  </section>
}
