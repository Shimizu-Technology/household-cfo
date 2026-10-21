import { expect, it } from 'vitest'
import { printableChallengeRecord, type PrivateChallengeRecord } from './privateChallengeRecord'
function fixture(): PrivateChallengeRecord { return { schema_version: 1, captured_at: '2026-10-21T15:43:40+10:00', actor_scope: { user_id: 1, household_id: 2 }, optional_reflections_included: false, enrollment: { cohort_id: 1, starts_on: '2026-10-05', ends_on: '2027-01-02', time_zone: 'Pacific/Guam', current_accepted_plan_version_id: 20 }, projection: { reporting_known: true, reported_cents: 1000, evidence_supported_cents: 500 }, current_entries: [{ id: 1, current_approved_version_id: 11 }], savings: { entry_versions: [{ id: 10, signed_cents: 2500, funding_source: 'new_money_reserved', effective_on: '2026-10-05', reason: 'Earlier value' }, { id: 11, signed_cents: 1000, funding_source: 'new_money_reserved', effective_on: '2026-10-05', reason: '<script>private()</script>' }], plan_versions: [{ id: 20, version_number: 1, target_cents: 50000, approved_at: '2026-10-05T01:00:00Z' }] }, current_daily_records: { checkpoints: [{ id: 2, current_version_id: 31 }], check_ins: [{ id: 5, current_version_id: 51 }], purchases: [{ id: 6, current_version_id: 61 }] }, daily: { checkpoint_versions: [{ id: 30, milestone_day: 30, version_number: 1 }, { id: 31, milestone_day: 30, version_number: 2 }], reflection_versions: [{ feeling_then: 'secret feeling', feeling_now: 'better' }], check_in_versions: [{ id: 50, local_on: '2026-10-19', spending_state: 'unknown' }, { id: 51, local_on: '2026-10-20', spending_state: 'no_spend' }], purchase_versions: [{ id: 60, amount_cents: 999, merchant: 'Earlier shop', purchased_on: '2026-10-19' }, { id: 61, amount_cents: 2000, merchant: 'Payless', purchased_on: '2026-10-21' }] } } }
it('distinguishes current versions from revision history and escapes participant text', () => {
  const html = printableChallengeRecord(fixture())
  const current = html.split('<h2>Money you set aside</h2>')[1].split('<h2>Your daily check-ins</h2>')[0]
  expect(current).toContain('$10.00'); expect(current).not.toContain('$25.00')
  expect(html).toContain('Earlier value'); expect(html).toContain('$500.00'); expect(html).toContain('$5.00')
  expect(html).toContain('&lt;script&gt;private()&lt;/script&gt;'); expect(html).not.toContain('<script>')
  expect(html).not.toContain('secret feeling'); expect(html).not.toContain('actor_scope')
  expect(html).toContain("default-src 'none'")
})
it('uses plain dates, one time-zone note and plain words instead of system terms', () => {
  const html = printableChallengeRecord(fixture())
  expect(html).toContain('Your 90 days: Mon, Oct 5 – Sat, Jan 2, 2027. Dates follow Guam time.')
  expect(html).toContain('Downloaded Wed, Oct 21, 2026, 3:43 PM.')
  expect(html).toContain('Set aside so far'); expect(html).toContain('Matched to a statement (included above, not extra)')
  for (const system of ['Pacific/Guam', 'T15:43', 'participant-reported', 'Evidence-supported', 'reserve', '2026-10-05']) expect(html).not.toContain(system)
})
it('includes the participant’s own current daily check-ins and confirmed purchases, but not earlier versions', () => {
  const html = printableChallengeRecord(fixture())
  const checkIns = html.split('<h2>Your daily check-ins</h2>')[1].split('<h2>Purchases you confirmed</h2>')[0]
  expect(checkIns).toContain('Tue, Oct 20, 2026'); expect(checkIns).toContain('No spending'); expect(checkIns).not.toContain('Mon, Oct 19')
  const purchases = html.split('<h2>Purchases you confirmed</h2>')[1].split('<h2>Your target changes</h2>')[0]
  expect(purchases).toContain('Payless'); expect(purchases).toContain('$20.00'); expect(purchases).not.toContain('Earlier shop')
})
it('never converts unknown savings to zero or includes feelings without explicit inclusion', () => {
  const record = fixture(); record.projection = { reporting_known: false, reported_cents: null, evidence_supported_cents: null }
  expect(printableChallengeRecord(record)).toContain('No amounts added yet')
  expect(printableChallengeRecord(record)).not.toContain('$0.00')
  record.optional_reflections_included = true
  expect(printableChallengeRecord(record)).toContain('secret feeling')
})

it('keeps current checkpoints separate from all approved revisions without exposing IDs or optional feelings', () => {
  const record = fixture()
  record.daily!.checkpoint_versions![0].approved_at = '2026-11-03T10:00:00Z'
  record.daily!.checkpoint_versions![1].approved_at = '2026-11-04T10:00:00Z'
  record.daily!.checkpoint_versions![0].feeling_then = 'private checkpoint feeling'
  const html = printableChallengeRecord(record)
  const current = html.split('<h2>Your Day 30, 60 and 90 check-ins</h2>')[1].split('<h2>Earlier versions of your check-ins</h2>')[0]
  const history = html.split('<h2>Earlier versions of your check-ins</h2>')[1].split('<h2>Earlier versions of your money records</h2>')[0]
  expect(current).toContain('Day 30 check-in'); expect(current).toContain('<td>2</td>')
  expect(current).toContain('Wed, Nov 4, 2026, 8:00 PM'); expect(current).not.toContain('Tue, Nov 3, 2026')
  expect(history).toContain('<td>1</td>'); expect(history).toContain('<td>2</td>')
  expect(history).toContain('Tue, Nov 3, 2026, 8:00 PM'); expect(history).toContain('Wed, Nov 4, 2026, 8:00 PM')
  expect(history).toContain('earlier ones aren’t extra progress or savings')
  expect(html).not.toContain('<td>30</td>'); expect(html).not.toContain('<td>31</td>')
  expect(html).not.toContain('secret feeling'); expect(html).not.toContain('private checkpoint feeling')
})
