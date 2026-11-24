import { describe, expect, it } from 'vitest'
import { changedDebtFields, ordinalDay, parseDueDay, parseOptionalAmount, pastDueStatus } from './debtArrears'

describe('debt arrears helpers', () => {
  it('writes due days the way people say them', () => {
    expect([1, 2, 3, 4, 11, 12, 13, 15, 21, 22, 23, 31].map(ordinalDay)).toEqual(['1st', '2nd', '3rd', '4th', '11th', '12th', '13th', '15th', '21st', '22nd', '23rd', '31st'])
  })

  it('keeps a blank past-due amount unknown and accepts 0 as caught up', () => {
    expect(parseOptionalAmount('')).toBeNull()
    expect(parseOptionalAmount('0')).toBe(0)
    expect(parseOptionalAmount('1500')).toBe(1500)
    expect(parseOptionalAmount('-5')).toBe('invalid')
  })

  it('accepts only days 1 through 31', () => {
    expect(parseDueDay('')).toBeNull()
    expect(parseDueDay('15')).toBe(15)
    expect(parseDueDay('0')).toBe('invalid')
    expect(parseDueDay('32')).toBe('invalid')
    expect(parseDueDay('2.5')).toBe('invalid')
  })
})

describe('debt form changes', () => {
  it('sends only the fields she changed, with what the form showed before', () => {
    const baseline = { label: 'Visa', balance: 1200, due_day: null as number | null, past_due: null as number | null }
    expect(changedDebtFields({ ...baseline, label: 'Travel Card' }, baseline)).toEqual({ changes: { label: 'Travel Card' }, expected: { label: 'Visa' } })
    expect(changedDebtFields({ ...baseline, past_due: 0 }, baseline)).toEqual({ changes: { past_due: 0 }, expected: { past_due: null } })
    expect(changedDebtFields(baseline, baseline)).toEqual({ changes: {}, expected: {} })
  })

  it('keeps $0 past due distinct from not entered', () => {
    expect(pastDueStatus(null)).toBeNull()
    expect(pastDueStatus(undefined)).toBeNull()
    expect(pastDueStatus(0)).toBe('caught_up')
    expect(pastDueStatus(95.4)).toBe('behind')
  })
})
