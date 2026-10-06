export type SetupSupportReason = 'practice_numbers' | 'wrong_setup' | 'upload_problem' | 'other'
export type SetupSupportStatus = 'requested' | 'in_review' | 'ready' | 'applied' | 'canceled' | 'declined'
export type SetupSupportRequest = {
  permissions?: { triage: boolean; prepare: boolean; decline: boolean }
  id: number
  status: SetupSupportStatus
  reason: SetupSupportReason
  reason_label: string
  participant_name: string
  user_id: number
  household_id: number
  cohort_id: number | null
  program_name: string | null
  lock_version: number
  review_id: number | null
  review_expires_at: string | null
  review_state: 'none' | 'pending' | 'expired' | 'stale' | 'applied' | 'canceled'
  created_at: string
  updated_at: string
}
export type SetupHelpState = {
  household_id: number
  cohort_id: number | null
  financial_generation: number
  available: boolean
  owner_required: boolean
  setup_complete: boolean
  self_restart_available: boolean
  blockers: Array<{ code: string; label: string }>
  latest_request: SetupSupportRequest | null
}
export const setupSupportReasons: Array<{ value: SetupSupportReason; label: string }> = [
  { value: 'practice_numbers', label: 'I entered practice numbers' },
  { value: 'wrong_setup', label: 'Several setup answers need correcting' },
  { value: 'upload_problem', label: 'An upload affected my setup' },
  { value: 'other', label: 'I need help reviewing a restart' },
]
export function setupSupportStatusLabel(status: SetupSupportStatus) {
  return { requested: 'Waiting for support', in_review: 'Support is reviewing', ready: 'Your review is ready', applied: 'Restart finished', canceled: 'Request canceled', declined: 'Corrections recommended' }[status]
}
export function activeSetupRequest(request: SetupSupportRequest | null) {
  return Boolean(request && ['requested', 'in_review', 'ready'].includes(request.status))
}
