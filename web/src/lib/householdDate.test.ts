import { describe, expect, it } from 'vitest'
import { guamTodayIso } from './householdDate'

describe('guamTodayIso', () => {
  it('uses the household date across the Guam UTC boundary', () => {
    expect(guamTodayIso(new Date('2026-10-01T15:30:00Z'))).toBe('2026-10-02')
  })
})
