import type { BaselineScope } from './financialBaseline'
import type { DailyCardState } from './dailyCheckIn'
import type { DailyReportIntake } from './savingsChallenge'
export type ChallengeChatCard = {
  id: number; kind: 'daily_report' | 'goal'; input: DailyReportIntake | { target_cents: number; expected_plan_version_id: number | null }
  state: Partial<DailyCardState> & { approved_plan_version_id?: number }; status: 'pending' | 'closed'; lock_version: number; enrollment_id: number; message_id: number
}
export type ChallengeChatCards = { records: ChallengeChatCard[]; actor_scope: BaselineScope; cohort_id: number; enrollment_id: number }
