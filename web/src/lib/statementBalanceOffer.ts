import type { StatementBalanceOffer, StatementBalanceTarget } from '../api'
import { formatHouseholdDay } from './householdDate'
import { formatReviewMoney } from './reviewMoney'

// Which account or card she picked for a statement balance, or that she is adding it.
export type BalanceChoice = number | 'new' | null

function owedSuffix(offer: StatementBalanceOffer) {
  return offer.kind === 'debt' ? ' owed' : ''
}

export function currentBalance(target: StatementBalanceTarget) {
  return target.balance_cents == null ? 'not known yet' : formatReviewMoney(target.balance_cents)
}

export function offerQuestion(offer: StatementBalanceOffer, choice: BalanceChoice, today = new Date()) {
  const amount = `${formatReviewMoney(offer.balance_cents)}${owedSuffix(offer)}`
  const day = formatHouseholdDay(offer.as_of_on, today)
  if (choice === 'new') return `Add ${offer.new_label} ${offer.kind === 'debt' ? 'to your debts' : 'to My Money'} with ${amount} from your ${day} statement?`
  const target = [offer.target, ...offer.choices].find((row) => row?.id === choice)
  if (target) return `Update ${target.label} to ${amount} from your ${day} statement?`
  return `Your ${day} statement for ${offer.statement_label} shows ${amount}. Which ${offer.kind === 'debt' ? 'card' : 'account'} is it?`
}
