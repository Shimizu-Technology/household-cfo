import { afterEach, describe, expect, it, vi } from 'vitest'
import { formatDay, formatRange, timeZoneLabel } from './plainDates'

afterEach(() => vi.unstubAllEnvs())

describe('plain dates', () => {
  it('formats a calendar day without a time-zone shift', () => {
    expect(formatDay('2026-10-17')).toBe('Sat, Oct 17')
    expect(formatDay('2027-01-01', { year: true })).toBe('Fri, Jan 1, 2027')
    // A device far west of UTC would shift a naive Date('2026-10-17') to Oct 16.
    vi.stubEnv('TZ', 'Pacific/Pago_Pago')
    expect(formatDay('2026-10-17')).toBe('Sat, Oct 17')
  })
  it('leaves anything that is not a real day unchanged', () => {
    expect(formatDay('2026-02-30')).toBe('2026-02-30')
    expect(formatDay('soon')).toBe('soon')
    expect(formatDay(null)).toBe('')
  })
  it('shows the year in a range only when it crosses into another year', () => {
    expect(formatRange('2026-10-17', '2027-01-14')).toBe('Sat, Oct 17 – Thu, Jan 14, 2027')
    expect(formatRange('2026-10-01', '2026-12-29')).toBe('Thu, Oct 1 – Tue, Dec 29')
    expect(formatRange('2026-10-01', null)).toBe('Thu, Oct 1')
  })
  it('names the time zone once in plain words', () => {
    expect(timeZoneLabel('Pacific/Guam')).toBe('Guam time')
    expect(timeZoneLabel('America/Los_Angeles')).toBe('Los Angeles time')
  })
})
