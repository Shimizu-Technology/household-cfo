import type { AdminCohort, AdminUser, CurrentUser } from '../api'

export const staff = (over: Partial<CurrentUser> = {}) => ({ id: 1, is_admin: false, is_staff: true, role: 'coach', full_name: 'Bethany Cruz', coach_workspaces: [{ id: 5, name: 'Mel program' }], ...over }) as unknown as CurrentUser
export const adminUser = () => staff({ id: 9, is_admin: true, role: 'admin', full_name: 'Mrs. Mel' })

export const group = (id: number, name: string, over: Partial<AdminCohort> = {}) => ({
  id, name, status: 'enrolling', starts_on: '2026-11-18', ends_on: null, notes: '', member_count: 0, participant_count: 0, staff_count: 0, setup_complete_count: 0,
  operational_summary: { available: false, period_days: 7, mia_requests: null, mia_failures: null, average_mia_latency_ms: null, uploads: null, upload_failures: null, participants_active: null },
  created_at: '2026-10-01T00:00:00Z', updated_at: '2026-10-02T00:00:00Z', created_by: { id: 1, email: 'c@example.invalid', full_name: 'Coach' }, ...over,
}) as unknown as AdminCohort

export const savings = (state: 'open' | 'paused' | 'ready' | 'not_set_up' = 'open', over = {}) => ({
  state, label: state, enabled: true, on_hold: false, capacity: 30, participant_count: 2, can_open: state !== 'open', can_pause: state === 'open', can_change: true,
  participants_can_join: true, blockers: [], recent_events: [], ...over,
}) as AdminCohort['savings_challenge']

export const person = (id: number, name: string, over: Record<string, unknown> = {}) => ({
  id, full_name: name, email: `${name.split(' ')[0].toLowerCase()}@example.test`, role: 'participant', invitation_status: 'accepted', invited_at: '2026-11-01T00:00:00Z', last_sign_in_at: null,
  can_resend_invitation: false, invite_email: { status: 'sent', error: null, workspace_scoped: false },
  cohorts: [{ id: 100 + id, role: 'participant', cohort: { id: 2, name: 'Bank of Guam 90 day savings', status: 'enrolling' } }],
  workspace: { setup_status: 'complete', setup_complete: true, last_safe_activity_at: null, signed_in: true, has_pending_review_work: false }, ...over,
}) as unknown as AdminUser
