// @vitest-environment jsdom
import { cleanup, render, fireEvent, screen, act } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import type { AnnualBudgetPlan, AnnualOutlookMonth } from '../api'
import { AnnualCashFlowChart, CategoryPressureList, ExpenseStackOverview } from './BudgetVisuals'

afterEach(cleanup)

function month(periodId: number, label: string, baselineSurplus: number): AnnualOutlookMonth {
  return { period_id: periodId, label, starts_on: `2026-${String(periodId).padStart(2, '0')}-01`, income: 5_000, category_plan: 5_000 - baselineSurplus, debt_minimums: 0, planned_outflow: 5_000 - baselineSurplus, baseline_surplus: baselineSurplus, expected_irregular: 0, expected_contributors: [] }
}

function planWith(months: AnnualOutlookMonth[]) {
  return { year: 2026, annual_outlook: { months } } as unknown as AnnualBudgetPlan
}

function bars(container: HTMLElement) {
  return Array.from(container.querySelectorAll<HTMLElement>('.cash-flow-month')).map((element) => element.style.getPropertyValue('--surplus-height'))
}

it('draws surpluses and shortfalls on one linear scale', () => {
  const { container } = render(<AnnualCashFlowChart plan={planWith([month(1, 'Jan', 600), month(2, 'Feb', 300), month(3, 'Mar', -300)])} />)
  // Rows are sized by the largest surplus and largest shortfall, so $300 up and $300 down draw the same length.
  expect(container.querySelector<HTMLElement>('.annual-cash-flow-chart')?.style.getPropertyValue('--cash-flow-rows')).toBe('600fr 300fr')
  expect(bars(container)).toEqual(['100%', '50%', '100%'])
  expect(container.querySelectorAll('.cash-flow-bar-above i')).toHaveLength(2)
  expect(container.querySelectorAll('.cash-flow-bar-below i')).toHaveLength(1)
})

it('collapses the shortfall area when no month falls short', () => {
  const { container } = render(<AnnualCashFlowChart plan={planWith([month(1, 'Jan', 0), month(2, 'Feb', 200)])} />)
  expect(container.querySelector<HTMLElement>('.annual-cash-flow-chart')?.style.getPropertyValue('--cash-flow-rows')).toBe('200fr 0fr')
  expect(bars(container)).toEqual(['0%', '100%'])
})


it('keeps every month selectable in a narrow chart without narrowing the targets', () => {
  let resize: ResizeObserverCallback | undefined
  vi.stubGlobal('ResizeObserver', class {
    constructor(callback: ResizeObserverCallback) { resize = callback }
    observe() {}
    disconnect() {}
  })
  try {
    const { container, rerender } = render(<AnnualCashFlowChart compact plan={planWith([month(1, 'Jan', 600), month(2, 'Feb', -300)])} />)
    act(() => resize?.([{ contentRect: { width: 280 } } as ResizeObserverEntry], {} as ResizeObserver))
    expect(container.querySelectorAll('button.cash-flow-month-trigger')).toHaveLength(0)
    const picker = screen.getByRole('combobox', { name: 'View month' })
    expect(screen.getAllByRole('option')).toHaveLength(2)
    fireEvent.change(picker, { target: { value: '2' } })
    expect(container.querySelector('.cash-flow-detail-panel')?.textContent).toContain('Feb 2026')
    expect(container.querySelector('.is-pinned strong')?.textContent).toBe('Feb')
    rerender(<AnnualCashFlowChart compact selectedMonthIndex={1} plan={planWith([month(1, 'Jan', 600), month(2, 'Feb', -300)])} />)
    expect(container.querySelector('.cash-flow-detail-summary')?.textContent).toContain('Report monthFeb 2026')
    act(() => resize?.([{ contentRect: { width: 800 } } as ResizeObserverEntry], {} as ResizeObserver))
    expect(container.querySelectorAll('button.cash-flow-month-trigger')).toHaveLength(2)
  } finally { vi.unstubAllGlobals() }
})
it('keeps unknown income off the surplus scale and detail panel', () => {
 const unknown = {...month(11, 'Nov', 0), income: null, baseline_surplus: null}
 const {container} = render(<AnnualCashFlowChart plan={planWith([unknown, month(12, 'Dec', 200)])} />)
 expect(screen.getByRole('button', {name:'Nov 2026: Not entered'})).toBeTruthy()
 expect(container.querySelector('.cash-flow-month-summary')?.textContent).toBe('—')
 expect(container.querySelector('.cash-flow-detail-panel')).toBeNull()
 expect(screen.queryByText('Every planned month has money left over.')).toBeNull()
})

it('keeps a known shortfall visible while another month is unknown', () => {
 const unknown = {...month(11, 'Nov', 0), income: null, baseline_surplus: null}
 render(<AnnualCashFlowChart plan={planWith([unknown, month(12, 'Dec', -200)])} />)
 expect(screen.getByText('1 planned month needs attention.')).toBeTruthy()
 expect(screen.queryByText('Every planned month has money left over.')).toBeNull()
})


it('shows pending uncategorized spending without invented zero plan or actual values', () => {
  const { container } = render(<CategoryPressureList title="Spending" eyebrow="November" positions={[{ id: 0, name: 'Uncategorized', stackKey: 'discretionary', stackLabel: 'Needs category', planned: 0, actual: 0, pending: 35, remaining: 0, active: true }]} />)
  expect(container.textContent).toContain('$35 pending')
  expect(container.textContent).toContain('Approved spending not known yet')
  expect(container.textContent).not.toContain('$0')
})

it('shows an uncategorized purchase waiting for review instead of a zero category plan in spending groups', () => {
  const { container } = render(<ExpenseStackOverview positions={[{ id: 0, name: 'Uncategorized', stackKey: 'discretionary', stackLabel: 'Needs category', planned: 0, actual: 0, pending: 35, remaining: 0, active: true }]} />)
  expect(container.textContent).toContain('$35 pending review')
  expect(container.textContent).not.toContain('$0')
})

it('does not present an unknown uncategorized amount as part of a known zero plan', () => {
  const {container} = render(<ExpenseStackOverview positions={[
    {id:0,name:'Uncategorized',stackKey:'discretionary',stackLabel:'Needs category',planned:0,actual:0,pending:35,remaining:0,active:true},
    {id:2,name:'Everyday spending',stackKey:'discretionary',stackLabel:'Discretionary',planned:0,actual:0,pending:0,remaining:0,active:true},
  ]} />)
  expect(container.querySelector('.stack-discretionary .expense-stack-row-heading b')?.textContent).not.toContain('$0')
})
