import { formatReviewMoney } from '../lib/reviewMoney'
import type { IgnoredTransactionDraft, RecentTransaction, SpendingReport, TransactionDraft } from '../api'
import { transactionDraftFromIgnored, transactionDraftFromLedgerRow, transactionItemName } from '../lib/transactionReview'
import './ReviewedTransactions.css'


function shortDate(value: string) {
  return new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(`${value}T00:00:00`))
}

type ReopenProps = {
  action: string | null
  disabled?: boolean
  errors?: Record<string, string>
  onReopen: (draft: TransactionDraft) => void | Promise<void>
}

/** "Reopen" on a confirmed row: voids the actual and returns its review card to pending. */
export function TransactionReopenButton({ transaction, action, disabled = false, errors = {}, onReopen }: ReopenProps & { transaction: RecentTransaction }) {
  const draft = transactionDraftFromLedgerRow(transaction)
  if (!draft) return null

  const reopening = action === `reopen-draft:${draft.id}`
  const label = reopening ? 'Reopening' : 'Reopen'
  return (<>
    <button
      type="button"
      className="secondary-button reviewed-transaction-action"
      aria-label={`${label} ${transactionItemName(draft)}`}
      disabled={disabled || Boolean(action)}
      onClick={() => { void Promise.resolve(onReopen(draft)).catch(() => { /* The shared handler owns the row error. */ }) }}
    >
      {label}
    </button>
    {errors[`purchase:${draft.id}`] && <p role="alert">{errors[`purchase:${draft.id}`]}</p>}
  </>)
}

export function IgnoredTransactionList({
  drafts,
  action,
  disabled = false,
  errors = {},
  onReopen,
  heading = 'Ignored this month',
}: ReopenProps & { drafts: IgnoredTransactionDraft[]; heading?: string }) {
  if (drafts.length === 0) return null

  return (
    <section className="reviewed-transaction-group" aria-label={heading}>
      <p className="group-label">{heading}</p>
      <p className="reviewed-transaction-note">Ignored transactions never counted toward actuals. Restore one to put it back in review.</p>
      <ul>
        {drafts.map((row) => {
          const draft = transactionDraftFromIgnored(row)
          const restoring = action === `reopen-draft:${draft.id}`
          const label = restoring ? 'Restoring' : 'Restore'
          return (
            <li className="reviewed-transaction-row" key={row.id}>
              <span>{shortDate(row.occurred_on)}</span>
              <strong>{row.merchant}</strong>
              <span>{row.category_name || 'Needs category'}</span>
              <b>{formatReviewMoney(Math.round((typeof row.amount_cents === 'number' ? row.amount_cents / 100 : row.amount) * 100))}</b>
              <button
                type="button"
                className="secondary-button reviewed-transaction-action"
                aria-label={`${label} ${transactionItemName(draft)}`}
                disabled={disabled || Boolean(action)}
                onClick={() => { void Promise.resolve(onReopen(draft)).catch(() => { /* The shared handler owns the row error. */ }) }}
              >
                {label}
              </button>
              {errors[`purchase:${draft.id}`] && <p role="alert">{errors[`purchase:${draft.id}`]}</p>}
            </li>
          )
        })}
      </ul>
    </section>
  )
}

/** Review-page list of this month's confirmed and ignored transactions, each one reversible. */
export function ReviewedTransactionsPanel({
  report,
  action,
  disabled = false,
  errors = {},
  onReopen,
}: ReopenProps & { report: SpendingReport | null }) {
  if (!report) return null
  const confirmed = report.transactions.filter((transaction) => transaction.transaction_draft_id)
  const ignored = report.ignored_drafts ?? []
  if (confirmed.length === 0 && ignored.length === 0) return null

  return (
    <section className="reviewed-transactions-panel" aria-labelledby="reviewed-transactions-heading">
      <div>
        <p className="group-label">Already reviewed · {report.period_label}</p>
        <h4 id="reviewed-transactions-heading">Change your mind?</h4>
        <p className="reviewed-transaction-note">Reopening a confirmed transaction removes it from this month’s confirmed spending and puts it back in review.</p>
      </div>
      {confirmed.length > 0 && (
        <section className="reviewed-transaction-group" aria-label="Confirmed this month">
          <p className="group-label">Confirmed this month</p>
          <ul>
            {confirmed.map((transaction) => (
              <li className="reviewed-transaction-row" key={transaction.id}>
                <span>{shortDate(transaction.occurred_on)}</span>
                <strong>{transaction.merchant}</strong>
                <span>{transaction.categories.join(', ') || 'Uncategorized'}</span>
                <b>{formatReviewMoney(Math.round((transaction.amount) * 100))}</b>
                <TransactionReopenButton transaction={transaction} errors={errors} action={action} disabled={disabled} onReopen={onReopen} />
              </li>
            ))}
          </ul>
        </section>
      )}
      <IgnoredTransactionList drafts={ignored} errors={errors} action={action} disabled={disabled} onReopen={onReopen} />
    </section>
  )
}
