import React from 'react'
import { createRoot } from 'react-dom/client'
import { CoachChallengeDashboard } from '../../src/components/CoachChallengeDashboard'
import { ChallengeExport } from '../../src/components/ChallengeExport'
import '../../src/App.css'
let revoked = false
const response = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } })
window.fetch = async (input, init) => {
  const path = new URL(String(input), 'http://localhost').pathname
  if (path.endsWith('/participants'))
    return response({
      actor_scope: { user_id: 10, coach_workspace_id: 20 },
      cohort_id: 1,
      records: [
        {
          enrollment_id: 2,
          participant: { id: 3, name: 'Fictional pilot participant' },
          participation_status: 'active',
          setup_status: 'plan_reviewed',
          check_in: { local_on: '2026-11-01', completed: null, availability: 'unavailable' },
          help_requests: [],
          more_help_requests: false,
        },
      ],
      next_cursor: null,
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
          records: [{ id: 4, checkpoint_day: 30, resolved_cutoff_on: '2026-11-30' }],
          scheduled_checkpoints: [
            { day: 30, cutoff_on: '2026-11-30' },
            { day: 60, cutoff_on: '2026-12-30' },
            { day: 90, cutoff_on: '2027-01-29' },
          ],
          next_cursor: null,
        })
  if (path.endsWith('/sponsor_exports/4'))
    return response({ actor_scope: { user_id: 10, coach_workspace_id: 20 }, cohort_id: 1, export_id: 4, report })
  return response({ errors: ['Unsupported synthetic request'] }, 422)
}
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
      <CoachChallengeDashboard userId={10} workspaceId={20} cohorts={[{ id: 1, name: 'Fictional savings cohort' }]} />
      <ChallengeExport cohortId={1} scope={{ user_id: 3, household_id: 9 }} />
    </main>
  )
}
createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <Fixture />
  </React.StrictMode>
)
