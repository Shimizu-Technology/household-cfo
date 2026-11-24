// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import type { MonthlyCloseData } from '../api'
import { ExpenseGroupNamesContext } from '../lib/expenseGroups'
import { MonthlyClosePanel } from './MonthlyClosePanel'

afterEach(() => {
  cleanup()
  vi.resetAllMocks()
})

function buildClose(overrides: Partial<MonthlyCloseData> = {}): MonthlyCloseData {
  return {
    year: 2026,
    month: 10,
    period_id: 101,
    period_label: 'October 2026',
    starts_on: '2026-10-01',
    ends_on: '2026-10-31',
    prior_year: 2026,
    prior_month: 9,
    prior_period_label: 'September 2026',
    plan_available: true,
    plan_starts_on: '2026-01-01',
    before_plan_start: false,
    status: 'complete',
    status_label: 'Month closed',
    household_id: 7,
    financial_generation: 1,
    income: {
      planned_cents: 540_000,
      actual_cents: 555_000,
      difference_cents: 15_000,
      prior_month_actual_cents: 540_000,
      prior_month_complete: true,
      change_from_prior_cents: 15_000,
      complete: true,
      partial: false,
      month_open: false,
      waiting_deposits: 0,
      coverage_note: 'From the statements you approved; other income may be missing.',
    },
    totals: {
      planned_spending_cents: 320_000,
      actual_spending_cents: 335_000,
      spending_difference_cents: 15_000,
      prior_actual_spending_cents: 310_000,
      spending_change_from_prior_cents: 25_000,
      has_spending_activity: true,
      prior_month_has_activity: true,
      debt_minimums_cents: 44_000,
      debt_minimums_known: true,
    },
    net: {
      planned_net_before_debt_cents: 220_000,
      actual_net_before_debt_cents: 220_000,
      net_before_debt_difference_cents: 0,
      planned_net_after_debt_cents: 176_000,
      actual_net_after_debt_cents: 176_000,
      net_after_debt_difference_cents: 0,
    },
    categories: [
      {
        id: 11,
        name: 'Groceries',
        stack_key: 'non_discretionary',
        stack_label: 'Must-pay bills',
        active: true,
        planned_cents: 70_000,
        actual_cents: 85_000,
        difference_cents: 15_000,
        prior_actual_cents: 65_000,
        change_from_prior_cents: 20_000,
        has_activity: true,
        prior_has_activity: true,
        refund_net_negative: false,
      },
      {
        id: 12,
        name: 'Dining Out',
        stack_key: 'discretionary',
        stack_label: 'Flexible spending',
        active: true,
        planned_cents: 25_000,
        actual_cents: 18_000,
        difference_cents: -7_000,
        prior_actual_cents: 28_000,
        change_from_prior_cents: -10_000,
        has_activity: true,
        prior_has_activity: true,
        refund_net_negative: false,
      },
    ],
    changes: {
      prior_month_has_activity: true,
      prior_period_label: 'September 2026',
      increases: [
        {
          category_id: 11,
          name: 'Groceries',
          stack_key: 'non_discretionary',
          stack_label: 'Must-pay bills',
          active: true,
          actual_cents: 85_000,
          prior_actual_cents: 65_000,
          change_from_prior_cents: 20_000,
        },
      ],
      decreases: [
        {
          category_id: 12,
          name: 'Dining Out',
          stack_key: 'discretionary',
          stack_label: 'Flexible spending',
          active: true,
          actual_cents: 18_000,
          prior_actual_cents: 28_000,
          change_from_prior_cents: -10_000,
        },
      ],
      income_change: {
        actual_cents: 555_000,
        prior_actual_cents: 540_000,
        change_from_prior_cents: 15_000,
      },
    },
    highlights: [
      'Money in came in at $5,550, $150 above the $5,400 plan.',
      'Category spending totaled $3,350, $150 over the $3,200 plan.',
      'Compared with September 2026, Groceries rose the most (+$200) while Dining Out dropped the most (-$100).',
    ],
    ...overrides,
  }
}

it('renders a complete monthly close with income, spending, separate debt payments, net cash flow, movers, and adjust action', async () => {
  const onAdjust = vi.fn()
  const loader = vi.fn().mockResolvedValue(buildClose())

  render(<MonthlyClosePanel year={2026} month={10} loadMonthlyClose={loader} onAdjustCategory={onAdjust} />)

  await screen.findByText('Month closed')
  expect(screen.getByRole('heading', { name: 'October 2026 close' })).toBeTruthy()
  expect(screen.getByText('$5,550')).toBeTruthy()
  expect(screen.getByText('$150 above plan')).toBeTruthy()
  expect(screen.getByText('$3,350')).toBeTruthy()
  expect(screen.getByText('$440')).toBeTruthy()
  expect(screen.getByText('Tracked separately from category spending.')).toBeTruthy()
  expect(screen.getByText('$2,200 actual')).toBeTruthy()
  expect(screen.getByText('$1,760 actual')).toBeTruthy()
  expect(screen.getByText('What changed from September 2026')).toBeTruthy()
  expect(screen.getByText('Biggest increases')).toBeTruthy()
  expect(screen.getByText('Biggest decreases')).toBeTruthy()

  fireEvent.click(screen.getByRole('button', { name: 'Adjust plan for Groceries' }))
  expect(onAdjust).toHaveBeenCalledWith(11)
})

it('hides income shortfall and actual net cash flow for partial or open months and shows coverage note', async () => {
  const partialClose = buildClose({
    status: 'partial',
    status_label: 'Partial statements',
    income: {
      planned_cents: 540_000,
      actual_cents: 270_000,
      difference_cents: null,
      prior_month_actual_cents: null,
      prior_month_complete: false,
      change_from_prior_cents: null,
      complete: false,
      partial: true,
      month_open: false,
      waiting_deposits: 1,
      coverage_note: 'Statements do not cover the whole month for every account. 1 deposit still needs your answer in Review.',
    },
    net: {
      planned_net_before_debt_cents: 220_000,
      actual_net_before_debt_cents: null,
      net_before_debt_difference_cents: null,
      planned_net_after_debt_cents: 176_000,
      actual_net_after_debt_cents: null,
      net_after_debt_difference_cents: null,
    },
    changes: {
      prior_month_has_activity: false,
      prior_period_label: 'September 2026',
      increases: [],
      decreases: [],
      income_change: null,
    },
  })

  render(<MonthlyClosePanel year={2026} month={10} loadMonthlyClose={vi.fn().mockResolvedValue(partialClose)} />)

  await screen.findByText('Partial statements')
  expect(screen.getByText('$2,700 so far')).toBeTruthy()
  expect(screen.getByText('Variance waits for complete statements')).toBeTruthy()
  expect(screen.getByText(/1 deposit still needs your answer in Review/)).toBeTruthy()
  expect(screen.queryByText(/under plan/)).toBeNull()
  expect(screen.queryByText(/actual$/)).toBeNull()
  expect(screen.getByText(/No confirmed activity in September 2026/)).toBeTruthy()
})

it('shows refund-negative notice and archived categories without an Adjust plan button', async () => {
  const closeWithRefundAndArchived = buildClose({
    categories: [
      {
        id: 21,
        name: 'Clothing',
        stack_key: 'discretionary',
        stack_label: 'Flexible spending',
        active: true,
        planned_cents: 15_000,
        actual_cents: -5_000,
        difference_cents: -20_000,
        prior_actual_cents: 12_000,
        change_from_prior_cents: -17_000,
        has_activity: true,
        prior_has_activity: true,
        refund_net_negative: true,
      },
      {
        id: 22,
        name: 'Old Gym',
        stack_key: 'discretionary',
        stack_label: 'Flexible spending',
        active: false,
        planned_cents: 0,
        actual_cents: 8_000,
        difference_cents: 8_000,
        prior_actual_cents: 8_000,
        change_from_prior_cents: 0,
        has_activity: true,
        prior_has_activity: true,
        refund_net_negative: false,
      },
    ],
  })

  render(
    <MonthlyClosePanel
      year={2026}
      month={10}
      loadMonthlyClose={vi.fn().mockResolvedValue(closeWithRefundAndArchived)}
      onAdjustCategory={vi.fn()}
    />,
  )

  await screen.findByText('Clothing')
  expect(screen.getByText('More came back in refunds than was spent.')).toBeTruthy()
  expect(screen.getByText('-$50')).toBeTruthy()
  expect(screen.getByText('Old Gym')).toBeTruthy()
  expect(screen.getByText('Archived')).toBeTruthy()
  expect(screen.getByText('Not in plan')).toBeTruthy()
  expect(screen.getByRole('button', { name: 'Adjust plan for Clothing' })).toBeTruthy()
  expect(screen.queryByRole('button', { name: 'Adjust plan for Old Gym' })).toBeNull()
})

it('guards against stale responses when switching months rapidly', async () => {
  let resolveSep!: (value: MonthlyCloseData) => void
  let resolveOct!: (value: MonthlyCloseData) => void
  const loader = vi.fn((_year: number, month: number) => new Promise<MonthlyCloseData>((resolve) => {
    if (month === 9) resolveSep = resolve
    if (month === 10) resolveOct = resolve
  }))

  const view = render(<MonthlyClosePanel year={2026} month={9} loadMonthlyClose={loader} />)
  view.rerender(<MonthlyClosePanel year={2026} month={10} loadMonthlyClose={loader} />)

  resolveOct(buildClose({ month: 10, period_label: 'October 2026' }))
  await screen.findByRole('heading', { name: 'October 2026 close' })

  // Earlier slower September response arrives late; must NOT overwrite October!
  resolveSep(buildClose({ month: 9, period_label: 'September 2026' }))
  await waitFor(() => {
    expect(screen.getByRole('heading', { name: 'October 2026 close' })).toBeTruthy()
  })
  expect(screen.queryByRole('heading', { name: 'September 2026 close' })).toBeNull()
})

it('shows an error alert and retries cleanly when Try again is clicked', async () => {
  const loader = vi.fn()
    .mockRejectedValueOnce(new Error('Could not reach the server.'))
    .mockResolvedValueOnce(buildClose())

  render(<MonthlyClosePanel year={2026} month={10} loadMonthlyClose={loader} />)

  const alert = await screen.findByRole('alert')
  expect(within(alert).getByText('Could not reach the server.')).toBeTruthy()

  fireEvent.click(within(alert).getByRole('button', { name: 'Try again' }))
  await screen.findByText('Month closed')
  expect(loader).toHaveBeenCalledTimes(2)
})

it('switches expense group headings when ExpenseGroupNamesContext changes between plain and method', async () => {
  const loader = vi.fn().mockResolvedValue(buildClose())
  const view = render(
    <ExpenseGroupNamesContext.Provider value="plain">
      <MonthlyClosePanel year={2026} month={10} loadMonthlyClose={loader} />
    </ExpenseGroupNamesContext.Provider>,
  )

  await screen.findByRole('heading', { name: 'Must-pay bills' })
  expect(screen.getByRole('heading', { name: 'Flexible spending' })).toBeTruthy()

  view.rerender(
    <ExpenseGroupNamesContext.Provider value="method">
      <MonthlyClosePanel year={2026} month={10} loadMonthlyClose={loader} />
    </ExpenseGroupNamesContext.Provider>,
  )

  expect(screen.getByRole('heading', { name: 'Non-discretionary' })).toBeTruthy()
  expect(screen.getByRole('heading', { name: 'Discretionary' })).toBeTruthy()
})
