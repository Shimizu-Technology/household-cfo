import type { CoachDailyPerson } from './coachChallengeApi'

// What a person needs from their coach today, in plain words.
export function dailyNeed(row: CoachDailyPerson) {
  const needs: string[] = []
  for (const help of row.setup_help) needs.push(({ upload_problem: 'Asked for help with an upload', practice_numbers: 'Asked for help replacing practice numbers', wrong_setup: 'Asked for help correcting setup', other: 'Asked for help starting again' } as Record<string, string>)[help.reason] ?? 'Asked for setup help')
  if (row.help_requests.length) needs.push('Asked for challenge help')
  for (const item of row.shared_items) needs.push(item === 'savings_plan_version' ? 'Shared their target plan with you' : item === 'summary' ? 'Shared their progress with you' : `Shared ${sharedItemLabel(item)} with you`)
  return [...new Set(needs)].join(' · ') || 'No open help requests'
}

const sharedItemLabel = (type: string) =>
  ({ document_source: 'original file', source_review_version: 'reviewed statement row', savings_entry_version: 'savings entry', savings_plan_version: 'target plan', chat_message: 'message' })[type] ?? 'record'
