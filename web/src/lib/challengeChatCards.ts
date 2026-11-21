import type { BaselineScope } from './financialBaseline'
import type { DailyCardState } from './dailyCheckIn'
import type { DailyReportIntake, SavingsIntake } from './savingsChallenge'
export type ChallengeChatCard = {
  id: number; kind: 'daily_report' | 'goal' | 'savings' | 'leave'; input: { intents: ('leave' | 'pause')[] } | DailyReportIntake | SavingsIntake | { target_cents: number; expected_plan_version_id: number | null; weekly_cents?: number | null }
  state: Partial<DailyCardState> & { approved_plan_version_id?: number; leave_intent?: 'leave' | 'pause'; support_request_id?: number }; status: 'pending' | 'closed'; lock_version: number; enrollment_id: number; message_id: number
  /** Her challenge's length in days; older cards read as 90. */
  challenge_length_days?: number | null
}
export type ChallengeChatCards = { records: ChallengeChatCard[]; actor_scope: BaselineScope; cohort_id: number; enrollment_id: number }
