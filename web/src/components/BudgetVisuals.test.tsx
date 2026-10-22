// @vitest-environment jsdom
import { cleanup, render, fireEvent, screen, act } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import type { AnnualBudgetPlan, AnnualOutlookMonth } from '../api'
import { AnnualCashFlowChart } from './BudgetVisuals'

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
