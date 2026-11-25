export type SavingsFundingSource = 'earned_income' | 'gift' | 'bonus' | 'new_money_reserved' | 'preexisting' | 'borrowed' | 'cash_advance' | 'existing_internal_money' | 'extra_debt_payment' | 'withdrawal'
/** What counts toward the goal: new money set aside, or that plus extra debt payments. */
export type ChallengeGoalCounts = 'savings' | 'savings_and_debt'
/** The rules an enrollment started with (or an offer would start with). Older payloads read as today's defaults. */
export type ChallengeRules = { length_days: number; checkpoint_days: number[]; suggested_goal_cents: number; goal_counts: ChallengeGoalCounts }
export const defaultChallengeRules: ChallengeRules = { length_days: 90, checkpoint_days: [30, 60, 90], suggested_goal_cents: 50_000, goal_counts: 'savings' }
export type SavingsEnrollment = { accepted_cohort_release_id: number; id: number; cohort_id: number; starts_on: string; ends_on: string; time_zone: string; status: string; policy_version: string; late_start_accepted: boolean; current_accepted_plan_version_id: number | null; approval_sequence: number; lock_version: number; challenge_length_days?: number; checkpoint_days?: number[]; suggested_goal_cents?: number; goal_counts?: ChallengeGoalCounts }
export type SavingsSpendingChange = { budget_category_id: number | null; category_name?: string | null; description: string; recurrence: 'unknown' | 'recurring' | 'one_off' | 'seasonal' | 'annual'; planned_reduction_cents: number | null }
export type SavingsPlanContext = { financial_baseline_version_id?: number | null; baseline_digest?: string | null; spending_changes?: SavingsSpendingChange[]; baseline_context?: { window_start_on: string; window_end_on: string; coverage_status: 'complete' | 'partial' | 'manual' } | null }
export type SavingsPlanContextInput = { financial_baseline_version_id: number | null; baseline_digest: string | null; spending_changes: Omit<SavingsSpendingChange, 'category_name'>[] }
export type SavingsPlanVersion = SavingsPlanContext & { id: number; previous_version_id: number | null; version_number: number; approval_sequence: number; target_cents: number | null; reason: string; approved_at: string }
export type SavingsPlanDraft = SavingsPlanContext & { id: number; base_plan_version_id: number | null; approved_plan_version_id: number | null; target_cents: number | null; reason: string; status: string; lock_version: number }
export type SavingsEntryVersion = { id: number; savings_entry_id: number; previous_version_id: number | null; version_number: number; approval_sequence: number; signed_cents: number; effective_on: string; currency: 'USD'; funding_source: SavingsFundingSource; evidence_supported_cents: number; evidence_status: 'not_linked' | 'linked' | 'stale' | 'revoked'; evidence_version_id?: number | null; evidence_head_lock_version?: number; reason: string; approved_at: string }
export type SavingsEntry = { id: number; current_approved_version_id: number | null; lock_version: number; current_approved_version: SavingsEntryVersion | null }
export type SavingsEntryDraft = { replaced?: boolean; id: number; savings_entry_id: number; base_version_id: number | null; base_entry_lock_version: number; approved_version_id: number | null; signed_cents: number; effective_on: string; funding_source: SavingsFundingSource; reason: string; status: string; lock_version: number }
export type SavingsProjection = { calculation_version: number; cutoff_on: string; reporting_known: boolean; zero_attested: boolean; reported_cents: number | null; evidence_supported_cents: number | null; target_cents: number | null; achieved: boolean | null; progress_basis_points: number | null; contribution_cents: number | null; withdrawal_cents: number | null; included_entry_count: number; excluded_entry_count: number; pending_entry_count: number; included_version_ids: string[]; approval_sequence: number; accepted_plan_version_id: number | null; zero_attestation_id: number | null }
export type SavingsCalendar = { local_today: string; time_zone: string; starts_on: string; ends_on: string; phase: 'upcoming' | 'active' | 'window_ended'; day: number | null; checkpoints: Record<string, string>; length_days?: number; checkpoint_days?: number[]; suggested_goal_cents?: number; goal_counts?: ChallengeGoalCounts }
export type SavingsOffer = { cohort_release_id: number; acceptance_digest: string; policy_version: string; time_zone: string; cohort_label: string; local_today: string; configured_starts_on: string | null; configured_ends_on: string | null; personal_starts_on: string | null; personal_ends_on: string | null; late_start_acceptance_required: boolean | null; accepting_enrollments: boolean; challenge_length_days?: number; checkpoint_days?: number[]; suggested_goal_cents?: number; goal_counts?: ChallengeGoalCounts }
export type ChallengeTimeline = { days: { day: number; local_on: string; future: boolean; check_in: 'unknown' | 'spending' | 'no_spend'; purchase_count: number; deposit_cents: number | null }[]; checkpoints_due: number[] }
export type SavingsChallenge = { timeline?: ChallengeTimeline; offer?: SavingsOffer; enrollment: SavingsEnrollment | null; accepted_plan: SavingsPlanVersion | null; projection: SavingsProjection | null; calendar?: SavingsCalendar; pending_entry_count?: number; pending_plan_count?: number; suggested_target_cents?: number; extra_debt_payment_cents?: number; extra_debt_payment_count?: number }
export type SavingsPage<T> = { records: T[]; next_cursor: number | null; actor_scope?: import('./financialBaseline').BaselineScope; enrollment_id?: number | null; cohort_id?: number | null }
export type SavingsMutation<T> = { record: T; replayed: boolean; challenge: SavingsChallenge }
export type SavingsPlanInput = Partial<SavingsPlanContextInput> & { target_cents: number | null; expected_plan_version_id: number | null; reason?: string }
export type SavingsPlanApproval = { accepted: true; expected_draft_lock_version: number; expected_plan_version_id: number | null }
export type SavingsEntryInput = { chat_card_id?: number; signed_cents: number; effective_on: string; funding_source: SavingsFundingSource; expected_version_id: number | null; entry_id?: number; expected_entry_lock_version?: number; reason?: string }
export type SavingsEntryApproval = { accepted: true; expected_draft_lock_version: number; expected_version_id: number | null; expected_entry_lock_version: number }

// Decimal strings become exact integer cents. No rounding, exponent notation,
// locale guessing, or silently truncating fractions of a cent.
export function savingsInputCents(value: string, allowZero = false): number {
  const text = value.trim()
  if (!/^(?:0|[1-9]\d*)(?:\.\d{1,2})?$/.test(text)) throw new Error('Enter US dollars with at most two decimal places, such as 25.50.')
  const [whole, fraction = ''] = text.split('.')
  const cents = Number(whole) * 100 + Number(fraction.padEnd(2, '0'))
  if (!Number.isSafeInteger(cents) || cents < (allowZero ? 0 : 1)) throw new Error(allowZero ? 'Use a valid amount in exact cents.' : 'Enter an amount greater than $0.00.')
  return cents
}
export function savingsDollars(cents: number | null): string {
  return cents === null ? 'Not yet reported' : new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(cents / 100)
}
// Whole dollars read as "$50"; any cents are kept ("$12.50"). For sentences and chat cards.
export function savingsPlainDollars(cents: number): string {
  if (cents % 100 !== 0) return savingsDollars(cents)
  const whole = new Intl.NumberFormat('en-US').format(Math.abs(cents) / 100)
  return `${cents < 0 ? '-' : ''}$${whole}`
}
// Targets read naturally in whole dollars; fractional dollars retain exact cents.
export const savingsTargetDollars = savingsPlainDollars
export function savingsInputDollars(cents: number): string {
  const magnitude = Math.abs(cents)
  return `${Math.floor(magnitude / 100)}.${String(magnitude % 100).padStart(2, '0')}`
}
export const savingsFundingOptions: { value: SavingsFundingSource; label: string; eligible: boolean }[] = [
  { value: 'new_money_reserved', label: 'New money I set aside after expenses', eligible: true },
  { value: 'earned_income', label: 'New earned income set aside', eligible: true },
  { value: 'gift', label: 'New gift money set aside', eligible: true },
  { value: 'bonus', label: 'New bonus money set aside', eligible: true },
  { value: 'preexisting', label: 'Savings I already had — excluded', eligible: false },
  { value: 'borrowed', label: 'Borrowed money — excluded', eligible: false },
  { value: 'cash_advance', label: 'Credit / cash advance — excluded', eligible: false },
  { value: 'existing_internal_money', label: 'Transfer, refund, or existing money — excluded', eligible: false },
]
/** The choices for her challenge: an extra debt payment is tracked alongside, and counts only when her rules say so. */
export function savingsFundingChoices(counts: ChallengeGoalCounts = 'savings'): typeof savingsFundingOptions {
  return [...savingsFundingOptions.slice(0, 4), { value: 'extra_debt_payment', label: counts === 'savings_and_debt' ? 'Extra payment on a card or loan, beyond the minimum' : 'Extra payment on a card or loan — tracked separately', eligible: counts === 'savings_and_debt' }, ...savingsFundingOptions.slice(4)]
}
export function savingsFundingLabel(value: SavingsFundingSource): string {
  if (value === 'extra_debt_payment') return 'Extra payment on a card or loan'
  return value === 'withdrawal' ? 'Withdrawal from challenge savings' : savingsFundingOptions.find((option) => option.value === value)?.label ?? value
}

/** The rules from an enrollment, calendar or offer; anything that predates them reads as 90 days, Day 30, 60 and 90, $500, savings only. */
export function challengeRules(source?: { challenge_length_days?: number; length_days?: number; checkpoint_days?: number[]; suggested_goal_cents?: number; goal_counts?: ChallengeGoalCounts } | null): ChallengeRules {
  const length = source?.length_days ?? source?.challenge_length_days
  return {
    length_days: length ?? defaultChallengeRules.length_days,
    checkpoint_days: source?.checkpoint_days?.length ? source.checkpoint_days : length ? [Math.round(length / 3), Math.round((length * 2) / 3), length] : defaultChallengeRules.checkpoint_days,
    suggested_goal_cents: source?.suggested_goal_cents ?? defaultChallengeRules.suggested_goal_cents,
    goal_counts: source?.goal_counts ?? defaultChallengeRules.goal_counts,
  }
}

/** What counts toward her goal, in her words. */
export function challengeCountsText(rules: ChallengeRules): string {
  return rules.goal_counts === 'savings_and_debt'
    ? 'New money you set aside counts toward your goal, and so do extra payments on a card or loan beyond the minimum.'
    : 'Only new money you set aside counts toward your goal. Extra debt payments are tracked alongside but don’t count.'
}

/** The check-in days and their dates, in order. Older calendars without checkpoint_days use the dates' keys. */
export function calendarCheckpoints(calendar: SavingsCalendar): Array<{ day: number; date: string }> {
  const days = calendar.checkpoint_days?.length ? calendar.checkpoint_days : Object.keys(calendar.checkpoints).map(Number).sort((a, b) => a - b)
  return days.filter(day => calendar.checkpoints[String(day)]).map(day => ({ day, date: calendar.checkpoints[String(day)] }))
}

export function checkedSavingsChallenge(value: SavingsChallenge): SavingsChallenge {
  const exact = (amount: number | null | undefined) => amount === null || (typeof amount === 'number' && Number.isSafeInteger(amount))
  if (value.enrollment) {
    const projection = value.projection
    const calendar = value.calendar
    if (!projection || !calendar || !calendar.local_today || !exact(projection.reported_cents) || !exact(projection.evidence_supported_cents) || !exact(projection.target_cents) || !Number.isSafeInteger(value.pending_entry_count) || !Number.isSafeInteger(value.pending_plan_count) || value.pending_entry_count! < 0 || value.pending_plan_count! < 0 || typeof projection.reporting_known !== 'boolean' || (projection.reporting_known && (projection.reported_cents === null || projection.evidence_supported_cents === null)) || (!projection.reporting_known && (projection.reported_cents !== null || projection.evidence_supported_cents !== null)) || (projection.progress_basis_points !== null && (!Number.isInteger(projection.progress_basis_points) || projection.progress_basis_points < 0 || projection.progress_basis_points > 10000))) throw new Error('Approved challenge data is incomplete. Refresh before reporting progress.')
    if (!Number.isSafeInteger(value.enrollment.lock_version) || !exact(value.accepted_plan?.target_cents ?? null)) throw new Error('The challenge version cannot be reviewed safely. Refresh before making changes.')
  }
  return value
}

export function savingsDefaultDate(calendar: SavingsCalendar | undefined): string {
  if (!calendar) return ''
  return calendar.local_today < calendar.starts_on ? calendar.starts_on : calendar.local_today > calendar.ends_on ? calendar.ends_on : calendar.local_today
}

export type SavingsIntake = { date_required?: boolean; staged_entry_id?: number; kind: 'purchase' | 'contribution' | 'withdrawal'; amount_cents: number; effective_on: string; merchant?: string; signed_cents?: number; approval_state: 'unreviewed_input'; counted: false; new_money_confirmation_required?: boolean; chat_card_id?: number; correction?: SavingsEntry; reason?: string }
export function checkedSavingsIntake(value: SavingsIntake | DailyReportIntake | null | undefined): SavingsIntake | null {
  if(!value || value.kind==='daily_report')return null
  if(!['purchase','contribution','withdrawal'].includes(value.kind) || value.approval_state!=='unreviewed_input' || value.counted!==false || !Number.isSafeInteger(value.amount_cents) || value.amount_cents<1 || value.amount_cents>2147483647 || !/^\d{4}-\d{2}-\d{2}$/.test(value.effective_on) && !(value.date_required === true && value.effective_on === ''))return null
  const date = new Date(`${value.effective_on}T00:00:00Z`)
  if(value.effective_on !== '' && (!Number.isFinite(date.getTime()) || date.toISOString().slice(0,10)!==value.effective_on))return null
  if(value.kind==='purchase' && (!value.merchant?.trim() || value.merchant.length>120))return null
  if(value.signed_cents!==undefined && value.signed_cents!==(value.kind==='withdrawal'?-value.amount_cents:value.amount_cents))return null
  return value
}

// A chat daily report: purchases or an explicit no-spend day, never saved or counted
// until the participant taps Save on the card that lists every item.
export type DailyReportPurchase = { amount_cents: number; merchant: string; purchased_on: string }
export type DailyReportIntake = { date_required?: boolean; kind: 'daily_report'; local_on: string; purchases: DailyReportPurchase[]; no_spend: boolean; feelings: { when_spent: string | null; now: string | null } | null; approval_state: 'unreviewed_input'; counted: false }
const isoDay = (value: unknown): value is string => {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false
  const date = new Date(`${value}T00:00:00Z`)
  // An impossible date ("2026-13-05") is rejected, never thrown.
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value
}
const shortText = (value: unknown, limit: number) => value === null || (typeof value === 'string' && value.length <= limit)
export function checkedDailyReport(value: unknown): DailyReportIntake | null {
  if (!value || typeof value !== 'object') return null
  const report = value as DailyReportIntake
  if (report.kind !== 'daily_report' || report.approval_state !== 'unreviewed_input' || report.counted !== false || (!isoDay(report.local_on) && !(report.date_required === true && report.local_on === '' && !report.no_spend)) || typeof report.no_spend !== 'boolean' || !Array.isArray(report.purchases) || report.purchases.length > 10) return null
  if (report.no_spend ? report.purchases.length > 0 : report.purchases.length === 0) return null
  if (!report.purchases.every((row) => row && Number.isSafeInteger(row.amount_cents) && row.amount_cents >= 1 && row.amount_cents <= 2147483647 && typeof row.merchant === 'string' && row.merchant.length <= 120 && (isoDay(row.purchased_on) || (report.date_required === true && row.purchased_on === '')))) return null
  if (report.feelings !== null && (typeof report.feelings !== 'object' || !shortText(report.feelings.when_spent, 140) || !shortText(report.feelings.now, 140))) return null
  return report
}

export function savingsPlanContextInput(plan: SavingsPlanContext | null | undefined): SavingsPlanContextInput | undefined {
  if (!plan || !Array.isArray(plan.spending_changes) || !Object.hasOwn(plan, 'financial_baseline_version_id') || !Object.hasOwn(plan, 'baseline_digest')) return undefined
  return { financial_baseline_version_id: plan.financial_baseline_version_id ?? null, baseline_digest: plan.baseline_digest ?? null, spending_changes: plan.spending_changes.map(({ budget_category_id, description, recurrence, planned_reduction_cents }) => ({ budget_category_id, description, recurrence, planned_reduction_cents })) }
}
export type SavingsPlanRequestStatus = ({state:'committed';record:unknown;replayed:true;challenge:SavingsChallenge}|{state:'unknown';can_retry:true}|{state:'in_flight'}) & {actor_scope:import('./financialBaseline').BaselineScope}
