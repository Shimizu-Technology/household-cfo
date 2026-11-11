import type { CoachDailyPerson } from './coachChallengeApi'

// What a person needs from their coach today, in plain words.
export function dailyNeed(row: CoachDailyPerson) {
  const needs: string[] = []
  for (const help of row.setup_help) needs.push(({ upload_problem: 'Asked for help with an upload', practice_numbers: 'Asked for help replacing practice numbers', wrong_setup: 'Asked for help correcting setup', other: 'Asked for help starting again', leave_challenge: 'Asked to pause or leave the challenge' } as Record<string, string>)[help.reason] ?? 'Asked for setup help')
  if (row.help_requests.length) needs.push('Asked for challenge help')
  for (const item of row.shared_items) needs.push(item === 'savings_plan_version' ? 'Shared their target plan with you' : item === 'summary' ? 'Shared their progress with you' : `Shared ${sharedItemLabel(item)} with you`)
  return [...new Set(needs)].join(' · ') || 'No open help requests'
}

const sharedItemLabel = (type: string) =>
  ({ document_source: 'original file', source_review_version: 'reviewed statement row', savings_entry_version: 'savings entry', savings_plan_version: 'target plan', chat_message: 'message' })[type] ?? 'record'

export function householdStatus(row: CoachDailyPerson) {
  return row.membership_status === 'invited' ? 'Invited · Hasn’t joined yet' : row.membership_status === 'revoked' ? 'Account access removed' : row.setup_status === 'complete' ? 'Joined · Setup done' : 'Joined · Setup not finished'
}

export function savingsStatus(row: CoachDailyPerson) {
  if (!row.enrollment_id) return row.membership_status === 'invited' ? 'Invited · Hasn’t joined yet' : row.membership_status === 'revoked' ? 'Account access removed' : 'Joined · Hasn’t started the challenge'
  return `${row.check_in?.completed === true ? 'Checked in today' : row.check_in?.completed === false ? 'No check-in yet' : 'Check-in unavailable'} · ${row.setup_status === 'plan_reviewed' ? 'Target confirmed' : 'No target confirmed yet'}`
}
