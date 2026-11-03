import { formatMonthRange } from './plainDates'
import { sourceAccountLabel, type SourceAccount, type SourceEvent } from './sourceReview'
import { statementCents } from './participantSourceReview'

// What a participant sees first about a statement: how many lines look right and the few that need her answer.
// The server decides which is which (ParticipantPlan), so this screen and "approve the rest" cannot disagree.
export type PlanAnswerId = 'as_read' | 'different' | 'leave_out' | 'edit'
export type PlanAttention = {
  event_id: number
  kind: 'unclear' | 'duplicate' | 'transfer' | 'card_payment' | 'refund' | 'no_category'
  event_type: SourceEvent['event_type']
  question: string
  answers: Array<{ id: PlanAnswerId; label: string }>
  merchant: string | null
  posted_on: string | null
  signed_amount_cents: number | null
  category_id: number | null
  category_name: string | null
}
export type StatementPlan = {
  total: number
  done: number
  ready_event_ids: number[]
  totals_check: 'matches' | 'mismatch' | 'count' | 'unchecked'
  first_on: string | null
  last_on: string | null
  attention: PlanAttention[]
}

export type LineKind = 'spending' | 'money_in' | 'moved' | 'card' | 'cash' | 'refund'
export type LineEdit = { kind: LineKind; merchant: string; posted_on: string; amount_cents: number; category_id: number | null }
export type LineDecision = { event_id: number; decision: 'as_read' | 'different' | 'leave_out' | 'edited'; edit?: LineEdit }
export type AccountChange = { source_account_id: number; label?: string; account_basis?: 'asset' | 'liability'; period_start_on?: string; period_end_on?: string }
export type ApproveLinesInput = { expect_ready_ids?: number[]; lines: LineDecision[]; accounts?: AccountChange[] }

export const LINE_KIND_OPTIONS: Array<{ value: LineKind; label: string }> = [
  { value: 'spending', label: 'Spending' },
  { value: 'money_in', label: 'Money in' },
  { value: 'moved', label: 'Moved between my accounts' },
  { value: 'card', label: 'Card or loan payment' },
  { value: 'cash', label: 'Cash taken out' },
  { value: 'refund', label: 'Refund' },
]

export function lineKindFor(type: SourceEvent['event_type'], signedCents: number | null): LineKind {
  switch (type) {
    case 'income': return 'money_in'
    case 'transfer': return 'moved'
    case 'debt_payment': return 'card'
    case 'cash_withdrawal': return 'cash'
    case 'refund': return 'refund'
    case 'interest': return (signedCents ?? -1) > 0 ? 'money_in' : 'spending'
    default: return 'spending'
  }
}

// Whole-dollar or two-decimal text a person would type; empty or malformed means "not entered", never zero.
export function parseLineAmount(text: string): number | null {
  try {
    const cents = statementCents(text.replace(/[$,\s]/g, ''))
    return cents != null && cents > 0 ? cents : null
  } catch { return null }
}

export function amountInputText(cents: number | null | undefined): string {
  return cents == null ? '' : (Math.abs(cents) / 100).toFixed(2)
}

// The name she approved wins over what the reader guessed from the file.
export function accountNames(accounts: SourceAccount[], reviewed: Array<{ source_account_id: number; approved: { tracked_account: { label: string } } | null }>): Record<number, string> {
  return Object.fromEntries(accounts.map((account) => [account.id, reviewed.find((row) => row.source_account_id === account.id)?.approved?.tracked_account.label ?? sourceAccountLabel(account, account.id)]))
}

export function describeAccounts(accounts: SourceAccount[], names: Record<number, string>): string {
  if (accounts.length === 0) return 'your statement'
  if (accounts.length > 1) return `${accounts.length} accounts`
  return names[accounts[0].id]
}

export function statementPeriodText(accounts: SourceAccount[], plan: StatementPlan): string {
  const starts = accounts.map((account) => account.period_start_on).filter((day): day is string => Boolean(day)).sort()
  const ends = accounts.map((account) => account.period_end_on).filter((day): day is string => Boolean(day)).sort()
  return formatMonthRange(starts[0] ?? plan.first_on, ends[ends.length - 1] ?? plan.last_on)
}

export function statementHeadline(accounts: SourceAccount[], names: Record<number, string>, plan: StatementPlan): string {
  const period = statementPeriodText(accounts, plan)
  return `${plan.total} ${plan.total === 1 ? 'line' : 'lines'} from ${describeAccounts(accounts, names)}${period ? `, ${period}` : ''}.`
}

export function statementCounts(plan: StatementPlan): { open: number; attention: number; sentence: string; action: string | null } {
  const attention = plan.attention.length
  const open = plan.ready_event_ids.length
  const look = `${attention} ${attention === 1 ? 'needs' : 'need'} a quick look.`
  if (open > 0 && attention > 0) return { open, attention, sentence: `${open} look right. ${look}`, action: open === 1 ? 'Approve the other one' : `Approve the other ${open}` }
  if (open > 0) return { open, attention, sentence: open === 1 ? 'It looks right.' : `All ${open} look right.`, action: open === 1 ? 'Approve it' : `Approve all ${open}` }
  if (attention > 0) return { open, attention, sentence: `${plan.done} saved. ${attention === 1 ? '1 still needs' : `${attention} still need`} a quick look.`, action: null }
  return { open, attention, sentence: plan.total === 0 ? 'No lines to review.' : `All ${plan.total} ${plan.total === 1 ? 'line is' : 'lines are'} saved.`, action: null }
}

export function totalsNote(check: StatementPlan['totals_check']): string | null {
  if (check === 'mismatch') return 'The totals on this statement don’t add up, so a line may be missing or wrong. We’ll keep that noted.'
  if (check === 'count') return 'The number of lines we found doesn’t match the number printed on your statement, so a line may be missing or extra. We’ll keep that noted.'
  if (check === 'unchecked') return 'This file doesn’t show totals, so we couldn’t check it against your statement.'
  return null
}

export function accountsNeedingBasis(accounts: SourceAccount[], reviewed: Array<{ source_account_id: number; approved: unknown }>): SourceAccount[] {
  return accounts.filter((account) => account.account_basis === 'unknown' && !reviewed.find((row) => row.source_account_id === account.id)?.approved)
}
