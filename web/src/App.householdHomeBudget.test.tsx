// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import type { ComponentProps } from 'react'
import { AnnualBudgetPlanner, HomeWelcomePanel } from './App'
import { YearOutlook } from './components/YearOutlook'
import { HomeScreen, MonthPlanLine } from './components/HomeScreen'
import { ExpenseStackOverview, MonthPlanSummary } from './components/BudgetVisuals'
import type { AnnualBudgetPlan, DashboardData, WorkspaceSetupStatus } from './api'

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
const dashboard = { action_center: { current_year: 2026, current_month_index: 9, current_month_label: 'October', transaction_review_count: 2, mia_action_review_count: 0 }, summary: { monthly_income: 6200, readiness_label: 'Red' }, month_answer: { money_in_cents: 620000, planned_out_cents: 402000, plan_left_cents: 218000, spent_so_far_cents: 22992, runway_months: 2, readiness_guidance: 'Build your cushion.', pending_count: 2 }, readiness_path: { available: false, unavailable_reason: 'Add liquid balances.' } } as DashboardData
const summary = { label: 'October 2026', income: 6200, planned: 3900, actual: 229.92, pending: 135.90 }
afterEach(() => { cleanup(); vi.resetAllMocks() })

it('keeps unknown income and plan distinct from confirmed zero and from missing activity', () => {
  const view = render(<MonthPlanSummary {...summary} income={0} planned={0} actual={0} pending={0} incomeKnown={false} planKnown={false} />)
  expect(screen.getAllByText('Not entered')).toHaveLength(2)
  expect(screen.getByText('No confirmed transactions yet')).toBeTruthy()
  expect(view.container.textContent).not.toContain('$0')
  view.rerender(<MonthPlanSummary {...summary} income={0} planned={0} actual={0} pending={0} />)
  expect(screen.getAllByText('$0')).toHaveLength(2)
  expect(screen.getByText('No confirmed transactions yet')).toBeTruthy()
})

it('reads money in, planned out and spent so far, without subtracting pending purchases', () => {
  render(<MonthPlanSummary {...summary} />)
  for (const amount of ['$6,200', '$3,900', '$229.92']) expect(screen.getByText(amount)).toBeTruthy()
  expect(screen.getByText('Your plan leaves $2,300 after planned spending.')).toBeTruthy()
  expect(screen.getByText('$135.90 pending review · not counted as spent')).toBeTruthy()
})

it('says plainly when the plan spends more than comes in, counting debt minimums', () => {
  render(<MonthPlanSummary {...summary} income={3000} debtMinimums={200} />)
  expect(screen.getByText('Planned out').parentElement?.textContent).toContain('$4,100')
  expect(screen.getByText('This month’s plan is $1,100 more than money in.')).toBeTruthy()
  expect(screen.queryByText(/over the plan/)).toBeNull()
})

it('makes Home money and the visible year lead, with one recommended review action', () => {
  const review = vi.fn()
  const { container } = render(<HomeScreen dashboard={dashboard} budget={{ annual_plan: plan } as ComponentProps<typeof HomeScreen>['budget']} onAskMia={vi.fn()} onReviewTransactions={review} onReviewMiaActions={vi.fn()} onReviewImports={vi.fn()} pendingImportCount={0} onOpenBudget={vi.fn()} />)
  expect(container.querySelectorAll('.year-outlook-months > li')).toHaveLength(2)
  expect(screen.getByText('2 months of breathing room')).toBeTruthy()
  expect(screen.getByText('$2,180')).toBeTruthy()
  expect(container.querySelector('.home-money-values')?.textContent).toContain('$4,020')
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
  expect(container.textContent).not.toContain('$0')
})

function plannerProps() {
  return { plan, isRealWorkspace: true, action: null, error: null, selectedMonthIndex: 9, spendingReport: null, spendingReportLoading: false, spendingReportError: null, newCategory: { name: '', stack_key: 'discretionary', monthly_amount: '', month_numbers: [10] }, onAskMia: vi.fn(), onUnsavedChangesChange: vi.fn(), onReviewTransactions: vi.fn() } as unknown as ComponentProps<typeof AnnualBudgetPlanner>
}
it('keeps the year on Home and starts Budget with this month’s groups and a Review link', () => {
  const props = plannerProps()
  const pendingPlan = { ...plan, pending_transaction_drafts: [{ id: 1, occurred_on: '2026-10-15', amount: 135.90, category_id: 1, status: 'pending' }] } as AnnualBudgetPlan
  const { container } = render(<AnnualBudgetPlanner {...props} plan={pendingPlan} />)
  expect(container.querySelector('.annual-outlook')).toBeNull()
  expect(container.querySelector('.expense-stack-overview')).toBeTruthy()
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
it('keeps Budget focused on setup when the monthly plan is unknown', () => {
  const { container } = render(<AnnualBudgetPlanner {...plannerProps()} planKnown={false} needsSetup />)
  expect(container.querySelectorAll('.cash-flow-bars i')).toHaveLength(0)
  expect(container.querySelector('.cash-flow-detail-panel')).toBeNull()
  expect(container.querySelector('.year-outlook')).toBeNull()
  expect(screen.queryByRole('button', { name: 'Ask Mia to update my plan' })).toBeNull()
})
it('labels four everyday expense groups with independent visual group marks', () => {
  const { container } = render(<ExpenseStackOverview positions={[]} />)
  for (const label of ['Must-pay bills', 'Flexible spending', 'Planned yearly costs', 'Surprise fund']) expect(screen.getByText(label)).toBeTruthy()
  const rows = container.querySelectorAll('.expense-stack-row')
  expect(new Set([...rows].map(row => row.className)).size).toBe(4)
  expect(within(rows[0] as HTMLElement).getByText('Must-pay bills')).toBeTruthy()
})

it('never recalculates Home from a different budget cache and preserves unknown and confirmed zero', () => {
 const props = { dashboard, budget: { annual_plan: { ...plan, monthly_income: {1: 999999} } }, onAskMia: vi.fn(), onReviewTransactions: vi.fn(), onReviewMiaActions: vi.fn(), onReviewImports: vi.fn(), pendingImportCount: 0 } as unknown as ComponentProps<typeof HomeScreen>
 const view = render(<HomeScreen {...props} />)
 expect(screen.getByText('$6,200')).toBeTruthy()
 view.rerender(<HomeScreen {...props} dashboard={{ ...dashboard, month_answer: { ...dashboard.month_answer!, money_in_cents: null, planned_out_cents: null, plan_left_cents: null, spent_so_far_cents: null } }} />)
 expect(screen.getAllByText('Not entered')).toHaveLength(3)
 expect(view.container.querySelector('.home-month-answer')?.textContent).not.toContain('$0')
 expect(screen.getByText('Enter your income, planned costs and debt minimums to see the year ahead.')).toBeTruthy()
 view.rerender(<HomeScreen {...props} dashboard={{ ...dashboard, month_answer: { ...dashboard.month_answer!, money_in_cents: 0, planned_out_cents: 0, plan_left_cents: 0, spent_so_far_cents: 0 } }} />)
 expect(screen.getAllByText('$0')).toHaveLength(4)
})

it('names debt minimums as the plan gap and links missing cushion balances', () => {
 const openDebt = vi.fn(), openAccounts = vi.fn()
 render(<HomeScreen dashboard={{...dashboard, month_answer: {...dashboard.month_answer!, planned_out_cents: null, plan_left_cents: null, runway_months: null, missing_plan_inputs: [{label:'debt minimums',destination:'debt'}], cushion_missing_inputs: [{label:'checking, savings, and emergency-fund balances',destination:'accounts'}], readiness_guidance:'Add checking, savings, and emergency-fund balances before judging your emergency cushion.'}}} budget={{annual_plan:plan} as ComponentProps<typeof HomeScreen>['budget']} onAskMia={vi.fn()} onReviewTransactions={vi.fn()} onReviewMiaActions={vi.fn()} onReviewImports={vi.fn()} pendingImportCount={0} onOpenDebt={openDebt} onOpenAccounts={openAccounts}/>)
 expect(screen.getByText('Still to add: debt minimums.')).toBeTruthy()
 fireEvent.click(screen.getByRole('button',{name:'Add account balances'}))
 expect(openAccounts).toHaveBeenCalledOnce()
 expect(screen.queryByText(/missing income or planned costs/)).toBeNull()
})

it('makes an irregular shortfall visible and withholds the year when an allocation is unknown', () => {
 const spikePlan = { ...plan, annual_outlook: { ...plan.annual_outlook, months: plan.annual_outlook.months.map((month, index) => index === 11 ? { ...month, baseline_surplus: -1320, planned_outflow: 7520, expected_contributors: [{ name: 'Holiday travel', amount: 3800 }] } : month) } }
 const view = render(<YearOutlook plan={spikePlan} />)
 expect(screen.getByText('$1,320 short')).toBeTruthy()
 expect(screen.getByText('Holiday travel: $3,800')).toBeTruthy()
 view.rerender(<YearOutlook plan={{ ...spikePlan, rows: [{ ...plan.rows[0], months: plan.rows[0].months.map((month, index) => index === 11 ? { ...month, allocation_missing: true } : month) }] }} />)
 expect(screen.queryByText('$1,320 short')).toBeNull()
 expect(screen.getByText('Enter your income, planned costs and debt minimums to see the year ahead.')).toBeTruthy()
})

it('keeps Home actions inside the enabled participant modules', () => {
 render(<HomeScreen dashboard={dashboard} budget={{ annual_plan: plan } as ComponentProps<typeof HomeScreen>['budget']} onAskMia={vi.fn()} onReviewTransactions={vi.fn()} onReviewMiaActions={vi.fn()} onReviewImports={vi.fn()} pendingImportCount={0} canAskMia={false} canReviewTransactions={false} />)
 expect(screen.queryByRole('button', { name: /Review .* purchase|Tell .* what changed|Plan details/ })).toBeNull()
})

it('puts one plan caveat below the whole money row and uses plain spent copy', () => {
 const {container} = render(<HomeScreen dashboard={dashboard} budget={{annual_plan: plan} as ComponentProps<typeof HomeScreen>['budget']} onAskMia={vi.fn()} onReviewTransactions={vi.fn()} onReviewMiaActions={vi.fn()} onReviewImports={vi.fn()} pendingImportCount={0} />)
 const caveat = screen.getByText('This is your plan, not your bank balance.')
 expect(caveat.previousElementSibling?.className).toBe('home-money-values')
 expect(container.querySelector('.home-spent')?.textContent).toBe('Spent so far this month: $229.92')
})
it('recovers missing debt minimums from Home without inventing a zero outflow', () => {
 const openDebt = vi.fn()
 render(<HomeScreen dashboard={{...dashboard, coach_read: {title: 'Debt minimums needed', body: 'Add minimums', action: 'open_debt'}, month_answer: {...dashboard.month_answer!, planned_out_cents: null, plan_left_cents: null}}} budget={{annual_plan: plan} as ComponentProps<typeof HomeScreen>['budget']} onAskMia={vi.fn()} onReviewTransactions={vi.fn()} onReviewMiaActions={vi.fn()} onReviewImports={vi.fn()} pendingImportCount={0} onOpenDebt={openDebt} />)
 expect(screen.getAllByText('Not entered')).toHaveLength(2)
 fireEvent.click(screen.getByRole('button', {name: 'Add debt minimums'}))
 expect(openDebt).toHaveBeenCalledOnce()
})
it('explains identical irregular costs once for grouped months', () => {
 const months = plan.annual_outlook.months.map((month,i) => i >= 10 ? {...month, income: 6200, planned_outflow: 7520, baseline_surplus: -1320, expected_irregular: 3800, expected_contributors: [{name: 'School costs', amount: 3800}]} : month)
 render(<YearOutlook plan={{...plan, annual_outlook: {...plan.annual_outlook, months}}} />)
 expect(screen.getByText('Nov–Dec')).toBeTruthy()
 expect(screen.getAllByText('School costs: $3,800')).toHaveLength(1)
 expect(screen.getByText('$1,320 short each month')).toBeTruthy()
})
it('distinguishes confirmed zero, missing category amounts, mixed subtotals and unknown debt minimums', () => {
 const position = {actual: 0, pending: 0, remaining: 0, active: true, stackLabel: 'Must-pay bills', stackKey: 'non_discretionary' as const}
 const view = render(<ExpenseStackOverview positions={[{...position,id:1,name:'Zero bill',planned:0},{...position,id:2,name:'Unknown bill',planned:0,allocationMissing:true},{...position,id:3,name:'Rent',planned:100}]} debtMinimums={null} />)
 const group = view.container.querySelector('.stack-non_discretionary') as HTMLElement
 expect(within(group).getByText('Zero bill').parentElement?.textContent).toBe('Zero bill$0')
 expect(within(group).getByText('Unknown bill').parentElement?.textContent).toBe('Unknown billNot entered')
 expect(within(group).getByText('Rent').parentElement?.textContent).toBe('Rent$100')
 expect(group.querySelector('.expense-stack-row-heading b')?.textContent).toBe('Not entered')
 expect(within(group).getByText('Add your debt minimums.')).toBeTruthy()
 expect(group.textContent).not.toContain('Plus $0')
 view.rerender(<ExpenseStackOverview positions={[{...position,id:1,name:'Zero bill',planned:0},{...position,id:3,name:'Rent',planned:100}]} debtMinimums={0} />)
 expect(view.container.querySelector('.expense-stack-row-heading b')?.textContent).toBe('$100 planned')
 expect(screen.getByText('Plus $0 in debt minimums.')).toBeTruthy()
})


it('locks every editable monthly value until the save and household refresh finish', () => {
  const props = plannerProps()
  const view = render(<AnnualBudgetPlanner {...props} />)
  fireEvent.click(screen.getByRole('button', { name: 'Manage manually' }))
  fireEvent.click(screen.getByRole('button', { name: 'Edit monthly plan' }))
  const amount = screen.getByRole('spinbutton', { name: 'Everyday costs planned for Oct' })
  fireEvent.change(amount, { target: { value: '4000' } })
  view.rerender(<AnnualBudgetPlanner {...props} action="save-budget-edits" />)
  for (const field of [amount, screen.getByRole('textbox', { name: 'Category name' }), screen.getByRole('combobox', { name: 'Expense stack' })]) expect(field).toHaveProperty('disabled', true)
  view.rerender(<AnnualBudgetPlanner {...props} />)
  expect(amount).toHaveProperty('disabled', false)
  expect(amount).toHaveProperty('value', '4000')
})

it('shows the shared approved month figures during partial setup and names only missing details', () => {
  const status: WorkspaceSetupStatus = { complete: false, completed_count: 3, required_count: 5, confirmed_fields: ['primary_income', 'fixed_expenses', 'flexible_spend'], required_fields: [], missing_fields: [{ key: 'household_name', label: 'Household name', confirmed: false }, { key: 'primary_goal', label: 'Primary goal', confirmed: false }] }
  render(<HomeWelcomePanel onPrimaryAction={vi.fn()} onManualSetup={vi.fn()} answer={{ ...dashboard.month_answer!, money_in_cents: 520000, planned_out_cents: 310000, plan_left_cents: 210000 }} status={status} />)
  expect(screen.getByRole('heading', { name: 'Your household plan' })).toBeTruthy()
  for (const value of ['$5,200', '$3,100', '$2,100']) expect(screen.getByText(value)).toBeTruthy()
  expect(screen.getByText('Still to add: household name, primary goal.')).toBeTruthy()
  expect(screen.queryByText('Not entered')).toBeNull()
})

it('uses the shared month answer in Budget and Wealth without treating unknown income as zero', () => {
  const view = render(<MonthPlanLine answer={{ ...dashboard.month_answer!, period_label: 'November 2026', money_in_cents: 520000, planned_out_cents: 310000, plan_left_cents: 210000 }} />)
  expect(screen.getByLabelText('Current month plan').textContent).toContain('November 2026 plan: $5,200 money in · $3,100 planned out · $2,100 left.')
  view.rerender(<MonthPlanLine answer={{ ...dashboard.month_answer!, money_in_cents: null, plan_left_cents: null }} />)
  expect(screen.getByLabelText('Current month plan').textContent).toContain('Not entered money in')
  expect(screen.getByLabelText('Current month plan').textContent).not.toContain('$0')
})
it('shows the join month and never turns an unknown outlook into a shortfall or zero', () => {
 const months = plan.annual_outlook.months.slice(10).map(month => ({...month, income: null, baseline_surplus: null}))
 render(<YearOutlook plan={{...plan, plan_starts_on: '2026-11-01', annual_outlook: {...plan.annual_outlook, months}}} />)
 expect(screen.getByText('Your plan starts in November.')).toBeTruthy()
 expect(screen.getAllByText('Income not known yet')).toHaveLength(2)
 expect(screen.queryByText(/short|\$0/)).toBeNull()
})
it('labels income on every known outlook group including a confirmed zero', () => {
 const months = plan.annual_outlook.months.slice(10).map(month => ({...month, income: 0, planned_outflow: 0, baseline_surplus: 0}))
 render(<YearOutlook plan={{...plan, annual_outlook: {...plan.annual_outlook, months}}} />)
 expect(screen.getByText('$0 planned out · $0 money in')).toBeTruthy()
})

it('asks for main income when an approved business amount is only a subtotal', () => {
 const answer = {...dashboard.month_answer!, main_income_missing:true, money_in_cents:null, plan_left_cents:null}
 const status = {completed_count:4, missing_fields:[{key:'primary_income',label:'Primary monthly income'}]} as WorkspaceSetupStatus
 render(<HomeWelcomePanel answer={answer} status={status} onPrimaryAction={vi.fn()} onManualSetup={vi.fn()} />)
 expect(screen.getByText('Still to add: your main income.')).toBeTruthy()
 expect(screen.getAllByText('Not entered')).toHaveLength(2)
 expect(screen.queryByText('Still to add: .')).toBeNull()
})

it('keeps approved pre-start spending on Home while the historical plan stays unknown', () => {
  const answer = { ...dashboard.month_answer!, year: 2026, month: 10, period_label: 'October 2026', plan_starts_on: '2026-11-01', before_plan_start: true, money_in_cents: null, planned_out_cents: null, plan_left_cents: null, spent_so_far_cents: 12300 }
  const { container } = render(<HomeScreen dashboard={{ ...dashboard, month_answer: answer }} budget={{ annual_plan: plan } as ComponentProps<typeof HomeScreen>['budget']} onAskMia={vi.fn()} onReviewTransactions={vi.fn()} onReviewMiaActions={vi.fn()} onReviewImports={vi.fn()} pendingImportCount={0} />)
  expect(container.querySelector('.home-spent')?.textContent).toContain('$123')
  expect(container.querySelector('.home-money-values')?.textContent).not.toContain('$0')
  expect(screen.getAllByText('Not entered')).toHaveLength(3)
})

for (const actual of [123, 0]) {
  it(`shows pre-start approved spending (${actual}) without inventing a historical plan`, () => {
    const historicalPlan = { ...plan, plan_starts_on: '2026-11-01', rows: plan.rows.map(row => ({ ...row, months: row.months.map((cell, i) => i === 9 ? { ...cell, planned: 0, actual, remaining: -actual } : cell) })) }
    const { container } = render(<AnnualBudgetPlanner {...plannerProps()} plan={historicalPlan} />)
    const historical = screen.getByRole('region', { name: 'Historical spending' })
    expect(historical.textContent).toContain('October 2026 has no plan to compare against')
    expect(historical.textContent).toContain(actual ? '$123' : 'Not known yet')
    expect(container.textContent).not.toMatch(/over now|unplanned|remaining now|\$0 planned/)
    expect(screen.queryByRole('heading', { name: 'Your spending groups' })).toBeNull()
  })
}
