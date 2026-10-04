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
  scheduled_checkpoints: Array<{ day: number; cutoff_on: string | null }>
  records: Array<{ id: number; checkpoint_day: number; resolved_cutoff_on: string; created_at: string }>
  next_cursor: number | null
}
const base = (id: number) => `/api/v1/challenge_cohorts/${id}`
const shared = (id: number) => `/api/v1/shared_challenges/${id}`
export const coachChallengeApi = {
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
