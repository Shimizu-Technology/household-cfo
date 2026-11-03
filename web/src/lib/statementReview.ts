import { formatMonthRange } from './plainDates'
import type { SourceAccount, SourceEvent } from './sourceReview'
import { statementCents } from './participantSourceReview'

// What a participant sees first about a statement: how many lines look right and the few that need her answer.
// The server decides which is which (ParticipantPlan), so this screen and "approve the rest" cannot disagree.
export type PlanAnswerId = 'as_read' | 'different' | 'leave_out' | 'edit' | 'keep'
export type PlanAttention = {
  event_id: number
  kind: 'unclear' | 'duplicate' | 'transfer' | 'card_payment' | 'refund' | 'no_category' | 'still_category'
  event_type: SourceEvent['event_type']
  question: string
  answers: Array<{ id: PlanAnswerId; label: string }>
  merchant: string | null
  posted_on: string | null
  signed_amount_cents: number | null
  category_id: number | null
  category_name: string | null
}
/** A line that looks right: the kind and category the server will save for it, exactly as she is shown them. */
export type PlanReady = { event_id: number; event_type: SourceEvent['event_type']; category_id: number | null; category_name: string | null; as_before: boolean }
export type CoverageAnswer = 'nothing_missing' | 'something_missing'
export type StatementPlan = {
  total: number
  done: number
  ready_event_ids: number[]
  ready: PlanReady[]
  coverage: { question: string | null; answer: CoverageAnswer | null }
  totals_check: 'matches' | 'mismatch' | 'count' | 'unchecked'
  first_on: string | null
  last_on: string | null
  attention: PlanAttention[]
}

export type LineKind = 'spending' | 'money_in' | 'moved' | 'card' | 'cash' | 'refund'
export type LineEdit = { kind: LineKind; merchant: string; posted_on: string; amount_cents: number; category_id: number | null }
/** What her screen showed for a line she says yes to; the server refuses the whole request if it no longer matches. */
export type LineShown = { event_type: SourceEvent['event_type']; category_id: number | null }
export type LineDecision = { event_id: number; decision: 'as_read' | 'different' | 'leave_out' | 'edited'; edit?: LineEdit; shown?: LineShown }
export type AccountChange = { source_account_id: number; label?: string; account_basis?: 'asset' | 'liability'; period_start_on?: string; period_end_on?: string }
export type ApproveLinesInput = { expect_ready_ids?: number[]; paged?: boolean; lines: LineDecision[]; accounts?: AccountChange[]; coverage_answer?: CoverageAnswer }
/** A long statement is approved this many lines at a time; each request saves exactly the lines shown, all or none. */
export const APPROVE_PAGE = 100

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

// The name comes from the server (the one she approved, else what the file says). A system label never reaches here.
export type AccountLabel = { name: string; last4: string }
export function accountNames(accounts: SourceAccount[], reviewed: Array<{ source_account_id: number; name?: string | null; last4?: string | null }>): Record<number, AccountLabel> {
  return Object.fromEntries(accounts.map((account) => {
    const row = reviewed.find((entry) => entry.source_account_id === account.id)
    return [account.id, { name: row?.name ?? '', last4: row?.last4 ?? '' }]
  }))
}

/** The account as a person would say it in a sentence; empty when the file gave nothing to go on. */
export function accountSentence(label: AccountLabel | undefined): string {
  if (!label) return ''
  if (label.name) return label.last4 ? `${label.name} ····${label.last4}` : label.name
  return label.last4 ? `your account ····${label.last4}` : ''
}

export function describeAccounts(accounts: SourceAccount[], names: Record<number, AccountLabel>): string {
  if (accounts.length > 1) return `${accounts.length} accounts`
  return (accounts.length === 1 && accountSentence(names[accounts[0].id])) || 'your statement'
}

export function statementPeriodText(accounts: SourceAccount[], plan: StatementPlan): string {
  const starts = accounts.map((account) => account.period_start_on).filter((day): day is string => Boolean(day)).sort()
  const ends = accounts.map((account) => account.period_end_on).filter((day): day is string => Boolean(day)).sort()
  return formatMonthRange(starts[0] ?? plan.first_on, ends[ends.length - 1] ?? plan.last_on)
}

export function statementHeadline(accounts: SourceAccount[], names: Record<number, AccountLabel>, plan: StatementPlan): string {
  const period = statementPeriodText(accounts, plan)
  return `${plan.total.toLocaleString('en-US')} ${plan.total === 1 ? 'line' : 'lines'} from ${describeAccounts(accounts, names)}${period ? `, ${period}` : ''}.`
}

export function statementCounts(plan: StatementPlan): { open: number; page: number; attention: number; sentence: string; action: string | null } {
  const attention = plan.attention.length
  const open = plan.ready.length
  const page = Math.min(open, APPROVE_PAGE)
  const look = `${attention} ${attention === 1 ? 'needs' : 'need'} a quick look.`
  if (open > APPROVE_PAGE) {
    const lead = attention > 0 ? `${open.toLocaleString('en-US')} look right. ${look}` : `All ${open.toLocaleString('en-US')} look right.`
    return { open, page, attention, sentence: `${lead} We’ll approve them ${APPROVE_PAGE} at a time.`, action: `Approve these ${APPROVE_PAGE}` }
  }
  if (open > 0 && attention > 0) return { open, page, attention, sentence: `${open} look right. ${look}`, action: open === 1 ? 'Approve the other one' : `Approve the other ${open}` }
  if (open > 0) return { open, page, attention, sentence: open === 1 ? 'It looks right.' : `All ${open} look right.`, action: open === 1 ? 'Approve it' : `Approve all ${open}` }
  if (attention > 0) return { open, page, attention, sentence: `${plan.done} saved. ${attention === 1 ? '1 still needs' : `${attention} still need`} a quick look.`, action: null }
  return { open, page, attention, sentence: plan.total === 0 ? 'No lines to review.' : `All ${plan.total.toLocaleString('en-US')} ${plan.total === 1 ? 'line is' : 'lines are'} saved.`, action: null }
}

/** "Dining out · as before": a category that comes only from what she chose for this shop earlier says so. */
export function readyCategoryLabel(line: PlanReady): string | null {
  if (!line.category_name) return null
  return line.as_before ? `${line.category_name} · as before` : line.category_name
}

/** The summary names the categories she did not see a guess for, so "approve" is never a surprise: "2 use a category you chose before: Dining out." */
export function asBeforeNote(plan: StatementPlan): string | null {
  const before = plan.ready.filter((line) => line.as_before && line.category_name)
  if (before.length === 0) return null
  const names = [...new Set(before.map((line) => line.category_name as string))]
  const listed = names.length <= 3 ? `: ${names.join(', ')}` : ''
  return `${before.length} ${before.length === 1 ? 'uses' : 'use'} a category you chose before${listed}.`
}

export function coverageMissingNote(): string {
  return 'Your lines are saved. We’ll keep this statement marked as not finished, because something may be missing.'
}

export function accountsNeedingBasis(accounts: SourceAccount[], reviewed: Array<{ source_account_id: number; approved: unknown }>): SourceAccount[] {
  return accounts.filter((account) => account.account_basis === 'unknown' && !reviewed.find((row) => row.source_account_id === account.id)?.approved)
}
