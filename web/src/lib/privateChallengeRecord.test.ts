import { expect, it } from 'vitest'
import { printableChallengeRecord, type PrivateChallengeRecord } from './privateChallengeRecord'
function fixture(): PrivateChallengeRecord { return { schema_version: 1, actor_scope: { user_id: 1, household_id: 2 }, optional_reflections_included: false, enrollment: { cohort_id: 1, starts_on: '2026-10-05', ends_on: '2027-01-02', time_zone: 'Pacific/Guam', current_accepted_plan_version_id: 20 }, projection: { reporting_known: true, reported_cents: 1000, evidence_supported_cents: 500 }, current_entries: [{ id: 1, current_approved_version_id: 11 }], savings: { entry_versions: [{ id: 10, signed_cents: 2500, funding_source: 'new_money_reserved', effective_on: '2026-10-05', reason: 'Earlier value' }, { id: 11, signed_cents: 1000, funding_source: 'new_money_reserved', effective_on: '2026-10-05', reason: '<script>private()</script>' }], plan_versions: [{ id: 20, version_number: 1, target_cents: 50000 }] }, current_daily_records: { checkpoints: [{ id: 2, current_version_id: 31 }] }, daily: { checkpoint_versions: [{ id: 30, milestone_day: 30, version_number: 1 }, { id: 31, milestone_day: 30, version_number: 2 }], reflection_versions: [{ feeling_then: 'secret feeling', feeling_now: 'better' }] } } }
it('distinguishes current versions from revision history and escapes participant text', () => {
  const html = printableChallengeRecord(fixture())
  const current = html.split('<h2>Current approved savings records</h2>')[1].split('<h2>Approved target history</h2>')[0]
  expect(current).toContain('$10.00'); expect(current).not.toContain('$25.00')
  expect(html).toContain('Earlier value'); expect(html).toContain('$500.00'); expect(html).toContain('$5.00')
  expect(html).toContain('&lt;script&gt;private()&lt;/script&gt;'); expect(html).not.toContain('<script>')
  expect(html).not.toContain('secret feeling'); expect(html).not.toContain('actor_scope')
  expect(html).toContain("default-src 'none'")
})
it('never converts unknown savings to zero or includes feelings without explicit inclusion', () => {
  const record = fixture(); record.projection = { reporting_known: false, reported_cents: null, evidence_supported_cents: null }
  expect(printableChallengeRecord(record)).toContain('Not yet reported')
  record.optional_reflections_included = true
  expect(printableChallengeRecord(record)).toContain('secret feeling')
})

it('keeps current checkpoints separate from all approved revisions without exposing IDs or optional feelings', () => {
  const record = fixture()
  record.daily!.checkpoint_versions![0].approved_at = '2026-11-03T10:00:00Z'
  record.daily!.checkpoint_versions![1].approved_at = '2026-11-04T10:00:00Z'
  record.daily!.checkpoint_versions![0].feeling_then = 'private checkpoint feeling'
  const html = printableChallengeRecord(record)
  const current = html.split('<h2>Current approved checkpoints</h2>')[1].split('<h2>Approved checkpoint revision history</h2>')[0]
  const history = html.split('<h2>Approved checkpoint revision history</h2>')[1].split('<h2>Savings revision history</h2>')[0]
  expect(current).toContain('Day 30'); expect(current).toContain('<td>2</td>')
  expect(current).toContain('2026-11-04T10:00:00Z'); expect(current).not.toContain('2026-11-03T10:00:00Z')
  expect(history).toContain('<td>1</td>'); expect(history).toContain('<td>2</td>')
  expect(history).toContain('2026-11-03T10:00:00Z'); expect(history).toContain('2026-11-04T10:00:00Z')
  expect(history).toContain('history is not additional progress or savings')
  expect(html).not.toContain('<td>30</td>'); expect(html).not.toContain('<td>31</td>')
  expect(html).not.toContain('secret feeling'); expect(html).not.toContain('private checkpoint feeling')
})
