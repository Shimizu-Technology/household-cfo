import type { PlanAnswerId, PlanAttention } from '../lib/statementReview'
import type { UnsavedAnswer } from '../lib/useStatementReview'
import { Button } from './Button'

/**
 * The one plain question about a statement line and its answers, as buttons. A category question lists her categories
 * (buttons when there are three or fewer, otherwise a menu). Used by the Statements screen and the chat card alike.
 */
export function StatementAnswers({ item, categories, disabled, unsaved, inlineCategory = false, onAnswer }: {
  item: PlanAttention
  categories: Array<{ id: number; name: string }>
  disabled: boolean
  /** Her last answer that has not been saved yet, kept pressed so she can see what she chose. */
  unsaved: UnsavedAnswer | null
  /** Offer her categories right here for "Change" on a suggested category too, so a one-word fix needs no sheet. */
  inlineCategory?: boolean
  onAnswer: (id: PlanAnswerId, categoryId?: number) => void
}) {
  const name = item.merchant ?? 'this line'
  const mine = unsaved?.eventId === item.event_id ? unsaved : null
  return <div className="statement-answers" role="group" aria-labelledby={`statement-question-${item.event_id}`}>
    {item.answers.map((choice) => (item.kind === 'no_category' || (inlineCategory && (item.kind === 'suggested_category' || item.kind === 'still_category'))) && choice.id === 'edit'
      ? categories.length > 0 && categories.length <= 3
        ? categories.map((category) => <Button key={category.id} variant={mine?.categoryId === category.id ? 'primary' : 'secondary'} aria-pressed={mine?.categoryId === category.id} disabled={disabled} aria-label={`${category.name}: ${name}`} onClick={() => onAnswer('edit', category.id)}>{category.name}</Button>)
        : categories.length === 0
          ? <Button key={choice.id} variant="secondary" disabled={disabled} onClick={() => onAnswer('edit')}>Choose a category</Button>
          : <select key={choice.id} aria-label={`Category for ${name}`} value={mine?.categoryId ?? ''} disabled={disabled} onChange={(event) => { if (event.target.value) onAnswer('edit', Number(event.target.value)) }}>
            <option value="">{choice.label}</option>
            {categories.map((category) => <option key={category.id} value={category.id}>{category.name}</option>)}
          </select>
      : <Button key={choice.id} variant="secondary" aria-pressed={mine?.choice === choice.id} disabled={disabled} aria-label={`${choice.label}: ${name}`} onClick={() => onAnswer(choice.id)}>{choice.label}</Button>)}
  </div>
}
