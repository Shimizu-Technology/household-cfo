import { savingsFixture } from '../test/savingsFixtures'
import { describe, expect, it } from 'vitest'
import { checkedSavingsIntake, type SavingsIntake, savingsDefaultDate, savingsDollars, savingsInputCents, savingsInputDollars } from './savingsChallenge'
describe('exact savings input', () => {
  it.each([['25.50', 2550], ['1', 100], ['0.01', 1], ['12.3', 1230], [' 500.00 ', 50000]])('converts %s to exact integer cents', (text, cents) => expect(savingsInputCents(text)).toBe(cents))
  it.each(['1.005', '1e3', '1,000', '-1', '.5', 'NaN', '', '0', '9007199254740993'])('rejects ambiguous, fractional-cent, nonpositive or unsafe %s', (value) => expect(() => savingsInputCents(value)).toThrow())
  it('defaults historical and upcoming dates only within the server-defined window', () => {
    const calendar = savingsFixture().calendar!
    expect(savingsDefaultDate({ ...calendar, local_today: '2027-01-01' })).toBe('2026-12-29')
    expect(savingsDefaultDate({ ...calendar, local_today: '2026-09-30' })).toBe('2026-10-01')
  })
  it('allows explicit zero corrections only when requested and preserves signed display', () => {
    expect(savingsInputCents('0.00', true)).toBe(0)
    expect(savingsInputDollars(-2550)).toBe('25.50')
    expect(savingsDollars(null)).toBe('Not yet reported')
    expect(savingsDollars(-2550)).toBe('-$25.50')
  })
})


describe('unreviewed Mia convenience input', () => {
  const input: SavingsIntake = { kind: 'purchase', amount_cents: 1250, effective_on: '2026-10-05', merchant: 'Fictional lunch', counted: false, approval_state: 'unreviewed_input' }
  it('accepts only valid exact, uncounted source input', () => {
    expect(checkedSavingsIntake(input)).toEqual(input)
    expect(checkedSavingsIntake({ ...input, kind: 'withdrawal', signed_cents: -1250 })).not.toBeNull()
    for (const unsafe of [{ counted: true }, { amount_cents: 12.5 }, { amount_cents: 0 }, { effective_on: '2026-02-30' }, { signed_cents: -1250 }, { merchant: '' }, { approval_state: 'approved' }]) {
      expect(checkedSavingsIntake({ ...input, ...unsafe } as SavingsIntake)).toBeNull()
    }
  })
})
