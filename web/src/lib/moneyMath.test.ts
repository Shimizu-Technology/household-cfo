import { describe, expect, it } from 'vitest'
import { addMoney, multiplyMoney, subtractMoney, sumMoney, formatMoneyOrUnknown } from './moneyMath'

describe('money math', () => {
  it('adds, subtracts, and multiplies through integer cents', () => {
    expect(addMoney(0.1, 0.2)).toBe(0.3)
    expect(subtractMoney(0.3, 0.1, 0.2)).toBe(0)
    expect(sumMoney([1.2, 2.4])).toBe(3.6)
    expect(multiplyMoney(8.33, 12)).toBe(99.96)
  })
})

describe('formatMoneyOrUnknown', () => {
  it('formats known amounts, including a real zero', () => {
    expect(formatMoneyOrUnknown(1234.5)).toBe('$1,234.50')
    expect(formatMoneyOrUnknown(0)).toBe('$0.00')
    expect(formatMoneyOrUnknown(-12)).toBe('-$12.00')
  })
  it('never shows a missing amount as $0', () => {
    expect(formatMoneyOrUnknown(null)).toBe('Not known yet')
    expect(formatMoneyOrUnknown(undefined)).toBe('Not known yet')
    expect(formatMoneyOrUnknown(Number.NaN)).toBe('Not known yet')
    expect(formatMoneyOrUnknown(undefined, 'Not set')).toBe('Not set')
  })
})

