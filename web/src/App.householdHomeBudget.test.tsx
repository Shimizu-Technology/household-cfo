// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import type { ComponentProps } from 'react'
import { AnnualBudgetPlanner, HomeWelcomePanel } from './App'
import { HomeScreen } from './components/HomeScreen'
import { ExpenseStackOverview, MonthPlanSummary } from './components/BudgetVisuals'
import type { AnnualBudgetPlan, DashboardData } from './api'

const labels = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
const plan: AnnualBudgetPlan = {
  year: 2026,
  months: labels.map((label, i) => ({ id: i + 1, label, starts_on: `2026-${String(i + 1).padStart(2, '0')}-01`, ends_on: `2026-${String(i + 1).padStart(2, '0')}-28`, status: 'open' })),
  monthly_income: Object.fromEntries(labels.map((_, i) => [i + 1, 6200])),
  monthly_debt_minimums: 120,
  income_sources: [], pending_transaction_drafts: [], recent_transactions: [],
  rows: [{ id: 1, name: 'Everyday costs', active: true, stack_key: 'discretionary', stack_label: 'Discretionary', planned_total: 48300, actual_total: 229.92, months: labels.map((_, i) => ({ period_id: i + 1, allocation_id: i + 1, planned: i === 11 ? 5400 : 3900, actual: i === 9 ? 229.92 : 0, remaining: 0 })) }],
  annual_outlook: { typical_monthly_outflow: 4020, months: labels.map((label, i) => ({ period_id: i + 1, label, starts_on: `2026-${String(i + 1).padStart(2, '0')}-01`, income: 6200, category_plan: i === 11 ? 5400 : 3900, debt_minimums: 120, planned_outflow: i === 11 ? 5520 : 4020, baseline_surplus: i === 11 ? 680 : 2180, expected_irregular: 0, expected_contributors: [] })), upcoming_spikes: [], next_irregular_month: null },
}
const dashboard = { action_center: { current_year: 2026, current_month_index: 9, current_month_label: 'October', transaction_review_count: 2, mia_action_review_count: 0 }, summary: { monthly_income: 6200, readiness_label: 'Red' }, readiness_path: { available: false, unavailable_reason: 'Add liquid balances.' } } as DashboardData
const summary = { label: 'October 2026', income: 6200, planned: 3900, actual: 229.92, pending: 135.90 }
afterEach(() => { cleanup(); vi.resetAllMocks() })

it('keeps unknown income and plan distinct from confirmed zero and from missing activity', () => {
  const view = render(<MonthPlanSummary {...summary} income={0} planned={0} actual={0} pending={0} incomeKnown={false} planKnown={false} />)
  expect(screen.getAllByText('Not entered')).toHaveLength(2)
  expect(screen.getByText('No confirmed transactions yet')).toBeTruthy()
  expect(view.container.textContent).not.toContain('$0.00')
  view.rerender(<MonthPlanSummary {...summary} income={0} planned={0} actual={0} pending={0} />)
  expect(screen.getAllByText('$0.00')).toHaveLength(2)
  expect(screen.getByText('No confirmed transactions yet')).toBeTruthy()
})

it('reads money in, planned out and spent so far, without subtracting pending purchases', () => {
  render(<MonthPlanSummary {...summary} />)
  for (const amount of ['$6,200.00', '$3,900.00', '$229.92']) expect(screen.getByText(amount)).toBeTruthy()
  expect(screen.getByText('Your plan leaves $2,300.00 after planned spending.')).toBeTruthy()
  expect(screen.getByText('$135.90 pending review · not counted as spent')).toBeTruthy()
})

it('says plainly when the plan spends more than comes in, counting debt minimums', () => {
  render(<MonthPlanSummary {...summary} income={3000} debtMinimums={200} />)
  expect(screen.getByText('Planned out').parentElement?.textContent).toContain('$4,100.00')
  expect(screen.getByText('This month’s plan is $1,100.00 more than money in.')).toBeTruthy()
  expect(screen.queryByText(/over the plan/)).toBeNull()
})

it('makes Home money and the visible year lead, with one recommended review action', () => {
  const review = vi.fn()
  const { container } = render(<HomeScreen dashboard={dashboard} budget={{ annual_plan: plan } as ComponentProps<typeof HomeScreen>['budget']} onAskMia={vi.fn()} onReviewTransactions={review} onReviewMiaActions={vi.fn()} onReviewImports={vi.fn()} pendingImportCount={0} onOpenBudget={vi.fn()} />)
  expect(container.querySelectorAll('.cash-flow-month')).toHaveLength(12)
  expect(container.querySelector('details .annual-cash-flow-chart')).toBeNull()
  expect(container.querySelectorAll('button:not(.text-button):not(.cash-flow-month-trigger)')).toHaveLength(1)
  fireEvent.click(screen.getByRole('button', { name: 'Review 2 purchases' }))
  expect(review).toHaveBeenCalledOnce()
  expect(screen.queryByRole('button', { name: /Tell .+ what changed/ })).toBeNull()
})

it('offers one Mia action when purchases are caught up', () => {
  render(<HomeScreen dashboard={{ ...dashboard, action_center: { ...dashboard.action_center, transaction_review_count: 0 } }} budget={{ annual_plan: plan } as ComponentProps<typeof HomeScreen>['budget']} onAskMia={vi.fn()} onReviewTransactions={vi.fn()} onReviewMiaActions={vi.fn()} onReviewImports={vi.fn()} pendingImportCount={0} />)
  expect(screen.getAllByRole('button', { name: /Tell .+ what changed/ })).toHaveLength(1)
})

it('uses one setup primary and one manual alternative on first Home', () => {
  const manual = vi.fn()
  const { container } = render(<HomeWelcomePanel onPrimaryAction={vi.fn()} onManualSetup={manual} />)
  expect(screen.getAllByRole('button')).toHaveLength(2)
  expect(container.querySelectorAll('.button--primary')).toHaveLength(1)
  fireEvent.click(screen.getByRole('button', { name: 'Enter my numbers' }))
  expect(manual).toHaveBeenCalledOnce()
  expect(container.textContent).not.toContain('$0.00')
})

function plannerProps() {
  return { plan, isRealWorkspace: true, action: null, error: null, selectedMonthIndex: 9, spendingReport: null, spendingReportLoading: false, spendingReportError: null, newCategory: { name: '', stack_key: 'discretionary', monthly_amount: '', month_numbers: [10] }, onAskMia: vi.fn(), onUnsavedChangesChange: vi.fn(), onReviewTransactions: vi.fn() } as unknown as ComponentProps<typeof AnnualBudgetPlanner>
}
it('puts the whole year before monthly detail and replaces the full queue with a Review link', () => {
  const props = plannerProps()
  const pendingPlan = { ...plan, pending_transaction_drafts: [{ id: 1, occurred_on: '2026-10-15', amount: 135.90, category_id: 1, status: 'pending' }] } as AnnualBudgetPlan
  const { container } = render(<AnnualBudgetPlanner {...props} plan={pendingPlan} />)
  const chart = container.querySelector('.annual-outlook')!
  const month = container.querySelector('.month-plan-summary')!
  expect(chart.compareDocumentPosition(month) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  expect(container.querySelector('.transaction-draft-card')).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: 'Review' }))
  expect(props.onReviewTransactions).toHaveBeenCalledOnce()
  expect(screen.getByText(/1 purchase waiting for review/)).toBeTruthy()
})
it('links Mia plan changes waiting for review to Ask Mia, separately from purchases', () => {
  const props = plannerProps()
  const pendingPlan = { ...plan, pending_mia_action_drafts: [{ id: 7, title: 'Move $50 to groceries', status: 'pending' }] } as unknown as AnnualBudgetPlan
  render(<AnnualBudgetPlanner {...props} plan={pendingPlan} />)
  expect(screen.getByText(/1 plan change from .* waiting for you/)).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: /^Review in / }))
  expect(props.onAskMia).toHaveBeenCalledOnce()
  expect(screen.queryByText(/purchases? waiting for review/)).toBeNull()
})
it('shows a quiet unknown year and one setup path before values are entered', () => {
  const { container } = render(<AnnualBudgetPlanner {...plannerProps()} incomeKnown={false} planKnown={false} needsSetup />)
  expect(container.querySelectorAll('.cash-flow-bars i')).toHaveLength(0)
  expect(container.querySelector('.cash-flow-detail-panel')).toBeNull()
  expect(screen.getAllByText('Not entered')).toHaveLength(2)
  expect(screen.queryByRole('button', { name: 'Ask Mia to update my plan' })).toBeNull()
})
it('labels four everyday expense groups with independent visual group marks', () => {
  const { container } = render(<ExpenseStackOverview positions={[]} />)
  for (const label of ['Must-pay bills', 'Flexible spending', 'Planned yearly costs', 'Surprise fund']) expect(screen.getByText(label)).toBeTruthy()
  const rows = container.querySelectorAll('.expense-stack-row')
  expect(new Set([...rows].map(row => row.className)).size).toBe(4)
  expect(within(rows[0] as HTMLElement).getByText('Must-pay bills')).toBeTruthy()
})
