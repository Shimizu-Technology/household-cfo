import { describe, expect, it } from 'vitest'
import type { AnnualBudgetPlan } from '../api'
import { budgetPositionTotals, budgetPositionsForMonth, transactionDraftBudgetImpacts } from './budgetPosition'

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

describe('cent-safe budget arithmetic', () => {
  it('does not report a one-cent plan as over when decimal additions equal the plan', () => {
    const plan = {
      year: 2026,
      months: [{ id: 8, label: 'Aug', starts_on: '2026-08-01', ends_on: '2026-08-31', status: 'open' }],
      rows: [{
        id: 3,
        name: 'Test category',
        stack_key: 'discretionary',
        stack_label: 'Discretionary',
        active: true,
        months: [{ planned: 0.3, actual: 0.1, remaining: 0.2 }],
        planned_total: 0.3,
        actual_total: 0.1,
      }],
      pending_transaction_drafts: [{
        id: 8,
        occurred_on: '2026-08-20',
        merchant: 'Pending merchant',
        amount: 0.1,
        status: 'pending',
        category_id: 3,
        category_name: 'Test category',
        splits: [],
      }],
      monthly_income: { 8: 1 },
      monthly_debt_minimums: 0,
      income_sources: [],
      annual_outlook: {},
      recent_transactions: [],
    } as unknown as AnnualBudgetPlan
    const candidate = {
      id: 9,
      occurred_on: '2026-08-21',
      merchant: 'Candidate merchant',
      amount: 0.1,
      status: 'pending',
      category_id: 3,
      category_name: 'Test category',
      splits: [],
    } as unknown as Parameters<typeof transactionDraftBudgetImpacts>[1]

    const positions = budgetPositionsForMonth(plan, 0)
    const impact = transactionDraftBudgetImpacts(plan, candidate).at(0)

    expect(budgetPositionTotals(positions)).toMatchObject({ planned: 0.3, actual: 0.1, pending: 0.1, remaining: 0.2 })
    expect(impact).toMatchObject({ otherPending: 0.1, projectedIfApproved: 0.3, remainingIfApproved: 0 })
  })
})
