import type { TransactionDraft } from '../api'
import { formatReviewMoney } from '../lib/reviewMoney'

// Same headline and detail-row presentation as Mia's plan-change cards.
export function PurchaseReviewSummary({ draft, date, needsCategory }: { draft: TransactionDraft; date: string; needsCategory: boolean }) {
  const headline = { amount_cents: draft.amount_cents ?? Math.round(draft.amount * 100), label: `at ${draft.merchant}` }
  const detailRows = [
    { label: 'Date', value: <time dateTime={draft.occurred_on}>{date}</time> },
    { label: 'Category', value: needsCategory ? 'Choose a category' : (draft.splits?.length ?? 0) > 1
      ? `${draft.splits!.length} categories` : draft.splits?.[0]?.category_name || draft.category_name || 'Choose a category' },
  ]
  return <>
    <div className="mia-change-headline"><strong className="mia-change-figure">{formatReviewMoney(headline.amount_cents)}</strong><span>{headline.label}</span></div>
    <dl className="mia-change-lines">{detailRows.map(row => <div key={row.label}><dt>{row.label}</dt><dd>{row.value}</dd></div>)}</dl>
  </>
}
