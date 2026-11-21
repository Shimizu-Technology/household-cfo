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
  return `Your ${day} statement for ${offer.statement_label} shows ${amount}. Which ${offer.kind === 'debt' ? 'debt' : 'account'} is it?`
}

// Any change to accounts or debts (an approval, an edit in My Money) asks every offer list to reload.
export const STATEMENT_BALANCE_CHANGED_EVENT = 'hcfo:statement-balance-changed'
export function announceStatementBalanceChange(source?: object) {
  globalThis.dispatchEvent(new CustomEvent(STATEMENT_BALANCE_CHANGED_EVENT, { detail: source }))
}

const TYPE_LABELS: Record<string, string> = {
  checking: 'Checking', savings: 'Savings', emergency_fund: 'Emergency fund', retirement: 'Retirement', investment: 'Investment', other: 'Other',
  credit_card: 'Credit card', student_loan: 'Student loan', auto_loan: 'Auto loan', mortgage: 'Mortgage', personal_loan: 'Personal loan', medical: 'Medical debt',
}
export function typeLabel(type: string) {
  return TYPE_LABELS[type] ?? type.replace(/_/g, ' ').replace(/^./, (letter) => letter.toUpperCase())
}
