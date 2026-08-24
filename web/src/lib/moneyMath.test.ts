import { describe, expect, it } from 'vitest'
import { addMoney, multiplyMoney, subtractMoney, sumMoney } from './moneyMath'

describe('money math', () => {
  it('adds, subtracts, and multiplies through integer cents', () => {
    expect(addMoney(0.1, 0.2)).toBe(0.3)
    expect(subtractMoney(0.3, 0.1, 0.2)).toBe(0)
    expect(sumMoney([1.2, 2.4])).toBe(3.6)
    expect(multiplyMoney(8.33, 12)).toBe(99.96)
  })
})
