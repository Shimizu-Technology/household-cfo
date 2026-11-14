import type { TransactionDraft } from '../api'
import { formatReviewMoney } from '../lib/reviewMoney'

// Same headline and detail-row presentation as Mia's plan-change cards.
export function PurchaseReviewSummary({ draft, date, needsCategory, effect }: { draft: TransactionDraft; date: string; needsCategory: boolean; effect?: string }) {
  const headline = { amount_cents: draft.amount_cents ?? Math.round(draft.amount * 100), label: draft.merchant }
  const categories = new Map(draft.splits?.map(split => [split.budget_category_id, split.category_name]))
  const category = needsCategory ? 'Choose a category' : categories.size > 1
    ? `${categories.size} categories` : categories.values().next().value || draft.category_name || 'Choose a category'
  return <>
    <div className="mia-change-headline purchase-review-headline"><span><span className="sr-only">at </span><strong>{headline.label}</strong></span><strong className="mia-change-figure">{formatReviewMoney(headline.amount_cents)}</strong></div>
    <p className="purchase-review-detail"><span><span className="sr-only">Category: </span>{category}</span> · <time dateTime={draft.occurred_on}><span className="sr-only">Date: </span>{date}</time>{effect && <> · {effect}</>}</p>
  </>
}
