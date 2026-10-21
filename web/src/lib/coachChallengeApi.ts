import { fetchPrivateJson } from '../api'

export type CoachChallengeScope = { user_id: number; coach_workspace_id: number }
export type CoachParticipant = {
  enrollment_id: number
  participant: { id: number; name: string }
  participation_status: string
  setup_status: string
  check_in: { local_on: string; completed: boolean | null; availability: string }
  help_requests: Array<{ id: number; status: string; issue_kind: string }>
  more_help_requests: boolean
}
export type CoachDailyPerson = Omit<CoachParticipant, 'enrollment_id' | 'check_in'> & {
  enrollment_id: number | null
  membership_status: 'invited' | 'joined' | 'revoked'
  check_in: CoachParticipant['check_in'] | null
  needs_help: boolean
  setup_help: Array<{ id: number; reason: string; status: string }>
  shared_items: string[]
}
export type DailyFilter = 'all' | 'needs_help' | 'checked_in' | 'not_checked_in' | 'invited' | 'joined' | 'setup_done'
export type CoachDailyPage = {
  actor_scope: CoachChallengeScope
  cohort_id: number
  program_type: 'savings' | 'household'
  can_invite: boolean
  counts: Record<DailyFilter, number>
  records: CoachDailyPerson[]
  next_offset: number | null
}
export function formatCoachTime(value: string) {
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? 'Date unavailable' : new Intl.DateTimeFormat('en-US', {
    timeZone: 'Pacific/Guam', weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
  }).format(date)
}
export type SharedRecordRef = { record_type: string; record_id: number }
export type SharedScopes = {
  enrollment_id: number
  summary_available: boolean
  selected_records: SharedRecordRef[]
  support_access: Array<{ id: number; expires_at: string; selected_records: SharedRecordRef[] }>
}
export type SponsorReport = {
  checkpoint_day: number
  cutoff_on: string
  active_consent_count_range: string
  bands: Array<{ band: string; count_range: string }>
  suppressed: boolean
  qualification: string
  exact_money_totals_included: false
  roster_included: false
  dynamic_filters_supported: false
}
export type SponsorIndex = {
  actor_scope: CoachChallengeScope
  cohort_id: number
  today_on?: string
  scheduled_checkpoints: Array<{ day: number; cutoff_on: string | null; sealable?: boolean }>
  records: Array<{ id: number; checkpoint_day: number; resolved_cutoff_on: string; created_at: string }>
  next_cursor: number | null
}
const base = (id: number) => `/api/v1/challenge_cohorts/${id}`
const shared = (id: number) => `/api/v1/shared_challenges/${id}`
export const coachChallengeApi = {
  daily: (id: number, search: string, filter: DailyFilter, offset: number, signal: AbortSignal) => {
    const query = new URLSearchParams({ view: 'daily', search, filter, offset: String(offset) })
    return fetchPrivateJson<CoachDailyPage>(`${base(id)}/participants?${query}`, { signal, cache: 'no-store' })
  },
  participants: (id: number, cursor: number | null, signal: AbortSignal) =>
    fetchPrivateJson<{
      actor_scope: CoachChallengeScope
      cohort_id: number
      records: CoachParticipant[]
      next_cursor: number | null
    }>(`${base(id)}/participants${cursor ? `?cursor=${cursor}` : ''}`, { signal, cache: 'no-store' }),
  scopes: (id: number, signal: AbortSignal) =>
    fetchPrivateJson<SharedScopes>(`${shared(id)}/scopes`, { signal, cache: 'no-store' }),
  summary: (id: number, signal: AbortSignal) =>
    fetchPrivateJson<{
      enrollment_id: number
      accepted_target_cents: number | null
      projection: {
        reported_cents: number | null
        evidence_supported_cents: number | null
        reporting_known: boolean
        achieved: boolean | null
      }
    }>(`${shared(id)}/summary`, { signal, cache: 'no-store' }),
  selected: (id: number, ref: SharedRecordRef, supportId: number | undefined, signal: AbortSignal) =>
    fetchPrivateJson<{
      record_type: string
      record?: Record<string, unknown>
      record_id?: number
      filename?: string
      source_available?: boolean
    }>(
      `${shared(id)}/selected?record_type=${encodeURIComponent(ref.record_type)}&record_id=${ref.record_id}${supportId ? `&support_access_id=${supportId}` : ''}`,
      { signal, cache: 'no-store' }
    ),
  help: (id: number, cursor: number | null, signal: AbortSignal) =>
    fetchPrivateJson<{
      records: Array<{ id: number; status: string; issue_kind: string }>
      next_cursor: number | null
    }>(`${shared(id)}/help${cursor ? `?cursor=${cursor}` : ''}`, { signal, cache: 'no-store' }),
  ticket: (id: number, ticket: number, signal: AbortSignal) =>
    fetchPrivateJson<{
      id: number
      issue_kind: string
      message: string
      status: string
      selected_records: SharedRecordRef[]
    }>(`${shared(id)}/support/${ticket}`, { signal, cache: 'no-store' }),
  ticketStatus: (id: number, ticket: number, status: 'triaged' | 'resolved', signal: AbortSignal) =>
    fetchPrivateJson<{ id: number; status: string }>(`${shared(id)}/support/${ticket}`, {
      signal,
      cache: 'no-store',
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ status }),
    }),
  exports: (id: number, cursor: number | null, signal: AbortSignal) =>
    fetchPrivateJson<SponsorIndex>(`${base(id)}/sponsor_exports${cursor ? `?cursor=${cursor}` : ''}`, {
      signal,
      cache: 'no-store',
    }),
  seal: (id: number, day: number, signal: AbortSignal) =>
    fetchPrivateJson<{ actor_scope: CoachChallengeScope; cohort_id: number; export_id: number; report: SponsorReport }>(
      `${base(id)}/sponsor_exports`,
      {
        signal,
        cache: 'no-store',
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ checkpoint_day: day, accepted: true }),
      }
    ),
  report: (id: number, exportId: number, signal: AbortSignal) =>
    fetchPrivateJson<{ actor_scope: CoachChallengeScope; cohort_id: number; export_id: number; report: SponsorReport }>(
      `${base(id)}/sponsor_exports/${exportId}`,
      { signal, cache: 'no-store' }
    ),
}

// Daily opens the existing guarded invitation task. CoachStudio owns the outer
// disclosure and dirty/pending lifecycle; keeping its form avoids a second write
// path with different navigation or mutation guards.
export function openCoachInvitation(source: HTMLElement) {
  const access = source.closest('[role="tabpanel"]')?.querySelector<HTMLDetailsElement>(':scope > .coach-access-disclosure')
  if (!access) return false
  access.dataset.inviteRequested = 'true'
  access.open = true
  access.dispatchEvent(new Event('coach-invite-requested'))
  return true
}

export function openCoachSetupHelp(source: HTMLElement, participantId: number) {
  const disclosure = source.closest('[role="tabpanel"]')?.querySelector<HTMLElement>(':scope > .setup-support-disclosure')
  if (!disclosure) return false
  disclosure.dataset.focusParticipant = String(participantId)
  const button = disclosure.querySelector<HTMLButtonElement>('.setup-support-disclosure-button')
  if (button?.getAttribute('aria-expanded') !== 'true') button?.click()
  disclosure.dispatchEvent(new Event('coach-setup-review-requested'))
  disclosure.scrollIntoView({ block: 'start' })
  return true
}
