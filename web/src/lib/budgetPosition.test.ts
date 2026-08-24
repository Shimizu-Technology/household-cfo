import { describe, expect, it } from 'vitest'
import type { AnnualBudgetPlan } from '../api'
import { budgetPositionTotals, budgetPositionsForMonth } from './budgetPosition'

describe('pending budget positions', () => {
  it('allocates split drafts and preserves uncategorized pending money', () => {
    const plan = {
      year: 2026,
      months: [{ id: 7, label: 'Jul', starts_on: '2026-07-01', ends_on: '2026-07-31', status: 'open' }],
      rows: [{
        id: 3,
        name: 'Dining Out',
        stack_key: 'discretionary',
        stack_label: 'Discretionary',
        active: true,
        months: [{ planned: 300, actual: 40, remaining: 260 }],
        planned_total: 300,
        actual_total: 40,
      }],
      pending_transaction_drafts: [{
        id: 9,
        occurred_on: '2026-07-10',
        merchant: 'Split receipt',
        amount: 100,
        status: 'pending',
        category_id: null,
        category_name: null,
        splits: [
          { id: 1, budget_category_id: 3, category_name: 'Dining Out', stack_key: 'discretionary', stack_label: 'Discretionary', amount: 60, amount_cents: 6_000, notes: null, confidence: 0.9 },
          { id: 2, budget_category_id: null, category_name: null, stack_key: null, stack_label: null, amount: 40, amount_cents: 4_000, notes: null, confidence: 0.9 },
        ],
      }],
      monthly_income: { 7: 8_500 },
      monthly_debt_minimums: 0,
      income_sources: [],
      annual_outlook: {},
      recent_transactions: [],
    } as unknown as AnnualBudgetPlan

    const positions = budgetPositionsForMonth(plan, 0)

    expect(positions.find((position) => position.id === 3)?.pending).toBe(60)
    expect(positions.find((position) => position.id === 0)).toMatchObject({ name: 'Uncategorized', pending: 40 })
    expect(budgetPositionTotals(positions).pending).toBe(100)
  })
})
