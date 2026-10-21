import { afterEach, describe, expect, it, vi } from 'vitest'
import { formatDay, formatGuamTimestamp, formatRange, timeZoneLabel } from './plainDates'

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
  it('identifies every financial period with a year', () => {
    expect(formatRange('2026-10-17', '2027-01-14')).toBe('Sat, Oct 17 – Thu, Jan 14, 2027')
    expect(formatRange('2026-10-01', '2026-12-29')).toBe('Thu, Oct 1 – Tue, Dec 29, 2026')
    expect(formatRange('2026-10-01', null)).toBe('Thu, Oct 1, 2026')
  })
  it('converts UTC and offset approval instants to the Guam calendar day', () => {
    expect(formatGuamTimestamp('2026-10-05T23:00:00Z')).toBe('Tue, Oct 6')
    expect(formatGuamTimestamp('2026-10-05T18:00:00-05:00', { year: true })).toBe('Tue, Oct 6, 2026')
    vi.stubEnv('TZ', 'Pacific/Pago_Pago')
    expect(formatGuamTimestamp('2026-10-05T23:00:00+00:00')).toBe('Tue, Oct 6')
  })
  it('names the time zone once in plain words', () => {
    expect(timeZoneLabel('Pacific/Guam')).toBe('Guam time')
    expect(timeZoneLabel('America/Los_Angeles')).toBe('Los Angeles time')
  })
})
