import type { IgnoredTransactionDraft, RecentTransaction, SpendingReport, TransactionDraft } from '../api'
import { transactionDraftFromIgnored, transactionDraftFromLedgerRow, transactionItemName } from '../lib/transactionReview'
import './ReviewedTransactions.css'

const currency = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', minimumFractionDigits: 2, maximumFractionDigits: 2 })

function shortDate(value: string) {
  return new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(`${value}T00:00:00`))
}

type ReopenProps = {
  action: string | null
  disabled?: boolean
  onReopen: (draft: TransactionDraft) => void
}

/** "Reopen" on a confirmed row: voids the actual and returns its review card to pending. */
export function TransactionReopenButton({ transaction, action, disabled = false, onReopen }: ReopenProps & { transaction: RecentTransaction }) {
  const draft = transactionDraftFromLedgerRow(transaction)
  if (!draft) return null

  const reopening = action === `reopen-draft:${draft.id}`
  const label = reopening ? 'Reopening' : 'Reopen'
  return (
    <button
      type="button"
      className="secondary-button reviewed-transaction-action"
      aria-label={`${label} ${transactionItemName(draft)}`}
      disabled={disabled || Boolean(action)}
      onClick={() => onReopen(draft)}
    >
      {label}
    </button>
  )
}

export function IgnoredTransactionList({
  drafts,
  action,
  disabled = false,
  onReopen,
  heading = 'Ignored this month',
}: ReopenProps & { drafts: IgnoredTransactionDraft[]; heading?: string }) {
  if (drafts.length === 0) return null

  return (
    <section className="reviewed-transaction-group" aria-label={heading}>
      <p className="eyebrow">{heading}</p>
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
              <b>{currency.format(typeof row.amount_cents === 'number' ? row.amount_cents / 100 : row.amount)}</b>
              <button
                type="button"
                className="secondary-button reviewed-transaction-action"
                aria-label={`${label} ${transactionItemName(draft)}`}
                disabled={disabled || Boolean(action)}
                onClick={() => onReopen(draft)}
              >
                {label}
              </button>
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
  onReopen,
}: ReopenProps & { report: SpendingReport | null }) {
  if (!report) return null
  const confirmed = report.transactions.filter((transaction) => transaction.transaction_draft_id)
  const ignored = report.ignored_drafts ?? []
  if (confirmed.length === 0 && ignored.length === 0) return null

  return (
    <section className="reviewed-transactions-panel" aria-labelledby="reviewed-transactions-heading">
      <div>
        <p className="eyebrow">Already reviewed · {report.period_label}</p>
        <h4 id="reviewed-transactions-heading">Change your mind?</h4>
        <p className="reviewed-transaction-note">Reopening a confirmed transaction removes it from this month’s actuals and puts it back in review.</p>
      </div>
      {confirmed.length > 0 && (
        <section className="reviewed-transaction-group" aria-label="Confirmed this month">
          <p className="eyebrow">Confirmed this month</p>
          <ul>
            {confirmed.map((transaction) => (
              <li className="reviewed-transaction-row" key={transaction.id}>
                <span>{shortDate(transaction.occurred_on)}</span>
                <strong>{transaction.merchant}</strong>
                <span>{transaction.categories.join(', ') || 'Uncategorized'}</span>
                <b>{currency.format(transaction.amount)}</b>
                <TransactionReopenButton transaction={transaction} action={action} disabled={disabled} onReopen={onReopen} />
              </li>
            ))}
          </ul>
        </section>
      )}
      <IgnoredTransactionList drafts={ignored} action={action} disabled={disabled} onReopen={onReopen} />
    </section>
  )
}
