import { describe, expect, it } from 'vitest'
import { formatHouseholdDay, formatHouseholdMonth, guamTodayIso } from './householdDate'

describe('guamTodayIso', () => {
  it('uses the household date across the Guam UTC boundary', () => {
    expect(guamTodayIso(new Date('2026-10-01T15:30:00Z'))).toBe('2026-10-02')
  })
})

it('shows month names and includes the year only outside the current Guam year', () => {
  const today = new Date('2026-11-02T00:00:00Z')
  expect(formatHouseholdDay('2026-11-03', today)).toBe('Nov 3')
  expect(formatHouseholdDay('2025-11-03', today)).toBe('Nov 3, 2025')
  expect(formatHouseholdMonth('2026-11-01', today)).toBe('Nov')
  expect(formatHouseholdMonth('2027-01-01', today)).toBe('Jan 2027')
})
it('keeps the stated day and uses Guam’s year across New Year', () => {
  const today = new Date('2026-12-31T15:00:00Z')
  expect(formatHouseholdDay('2027-01-01', today)).toBe('Jan 1')
  expect(formatHouseholdDay('2026-12-31', today)).toBe('Dec 31, 2026')
  expect(formatHouseholdMonth('2027-01-01', today)).toBe('Jan')
})
