import React from 'react'
import { createRoot } from 'react-dom/client'
import { TodaySection } from '../../src/admin/sections/TodaySection'
import { ReportsSection } from '../../src/admin/sections/ReportsSection'
import type { CurrentUser } from '../../src/api'
import { ChallengeExport } from '../../src/components/ChallengeExport'
import '../../src/App.css'
let revoked = false
;(window as unknown as { __revoke: () => void }).__revoke = () => { revoked = true }
const response = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } })
window.fetch = async (input, init) => {
  const url = new URL(String(input), 'http://localhost')
  const path = url.pathname
  const group = (id: number, name: string, savings: boolean) => ({
    id, name, status: 'active', starts_on: '2026-11-01', ends_on: null, notes: '', member_count: 1, participant_count: 1, staff_count: 0, setup_complete_count: 0,
    savings_challenge: { state: savings ? 'open' : 'not_set_up', label: 'Open', enabled: savings, on_hold: false, capacity: 30, participant_count: 1, can_open: false, can_pause: savings, can_change: true, participants_can_join: true, blockers: [], recent_events: [] },
    operational_summary: { available: false, period_days: 7, mia_requests: null, mia_failures: null, average_mia_latency_ms: null, uploads: null, upload_failures: null, participants_active: null },
    created_at: '2026-10-01T00:00:00Z', updated_at: '2026-10-01T00:00:00Z', created_by: { id: 10, email: 'c@example.invalid', full_name: 'Coach' },
  })
  if (path.endsWith('/admin/cohorts')) return response({ cohorts: [group(1, 'Fictional savings group', true), group(2, 'Household group', false)] })
  if (path.endsWith('/admin/users')) return response({ users: [] })
  if (path.endsWith('/setup_support_requests')) return response({ records: [], next_cursor: null })
  if (path.endsWith('/participants'))
    return response({
      actor_scope: { user_id: 10, coach_workspace_id: 20 },
      cohort_id: path.includes('/2/') ? 2 : 1,
      program_type: path.includes('/2/') ? 'household' : 'savings', can_invite: false, counts: { all: 1, needs_help: 1, checked_in: 0, not_checked_in: 0, invited: 0, joined: 1, setup_done: 0 },
      records: [
        {
          enrollment_id: path.includes('/2/') ? null : 2,
          membership_status: 'joined', needs_help: true, setup_help: path.includes('/2/') ? [{ id: 9, reason: 'upload_problem', status: 'requested' }] : [], shared_items: [],
          participant: { id: 3, name: path.includes('/2/') ? 'Elena' : 'Fictional pilot participant' },
          participation_status: 'active',
          setup_status: 'plan_reviewed',
          check_in: { local_on: '2026-11-01', completed: null, availability: 'unavailable' },
          help_requests: [],
          more_help_requests: false,
        },
      ],
      next_offset: null,
    })
  if (path.endsWith('/scopes'))
    return revoked
      ? response({ errors: ['Synthetic sharing revoked'] }, 403)
      : response({ enrollment_id: 2, summary_available: true, selected_records: [], support_access: [] })
  if (path.endsWith('/summary'))
    return response({
      enrollment_id: 2,
      accepted_target_cents: 50000,
      projection: { reported_cents: 10000, evidence_supported_cents: 5000, reporting_known: true, achieved: false },
    })
  const report = {
    checkpoint_day: 30,
    cutoff_on: '2026-11-30',
    active_consent_count_range: 'suppressed',
    bands: [],
    suppressed: true,
    qualification: 'Fictional suppressed report. No participant amounts or identities.',
    exact_money_totals_included: false,
    roster_included: false,
    dynamic_filters_supported: false,
  }
  if (path.endsWith('/sponsor_exports'))
    return init?.method === 'POST'
      ? response({ actor_scope: { user_id: 10, coach_workspace_id: 20 }, cohort_id: 1, export_id: 4, report })
      : response({
          actor_scope: { user_id: 10, coach_workspace_id: 20 },
          cohort_id: 1,
          records: [{ id: 4, checkpoint_day: 30, resolved_cutoff_on: '2026-01-30' }],
          scheduled_checkpoints: [
            { day: 30, cutoff_on: '2026-01-30', sealable: true },
            { day: 60, cutoff_on: '2026-03-01', sealable: true },
            { day: 90, cutoff_on: '2099-03-31', sealable: false },
          ],
          next_cursor: null,
        })
  if (path.endsWith('/sponsor_exports/4'))
    return response({ actor_scope: { user_id: 10, coach_workspace_id: 20 }, cohort_id: 1, export_id: 4, report })
  return response({ errors: ['Unsupported synthetic request'] }, 422)
}
const coach = { id: 10, is_admin: false, is_staff: true, role: 'coach', admin_sections: ['today', 'people', 'groups', 'coaching', 'reports', 'support', 'settings'].map(key => ({ key, label: key, access: 'full' })) } as unknown as CurrentUser
export function Fixture() {
  return (
    <main style={{ padding: 16, maxWidth: 1200, margin: 'auto' }}>
      <p>Fictional local component QA. No real participant records, authentication or report delivery.</p>
      <button
        onClick={() => {
          revoked = true
        }}
      >
        Synthetic revoke sharing
      </button>
      <TodaySection currentUser={coach} />
      <ReportsSection currentUser={coach} />
      <ChallengeExport cohortId={1} scope={{ user_id: 3, household_id: 9 }} />
    </main>
  )
}
createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <Fixture />
  </React.StrictMode>
)
