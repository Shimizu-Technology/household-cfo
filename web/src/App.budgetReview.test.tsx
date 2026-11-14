// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import type { AnnualBudgetPlan, SpendingReport, TransactionDraft } from './api'
import { AnnualBudgetPlanner, TransactionDraftReviewStack } from './App'
import { BudgetPlanStrip, ExpenseStackOverview } from './components/BudgetVisuals'
import { ReviewConfirmedCard } from './components/ReviewConfirmedCard'
import { ReviewedTransactionsPanel } from './components/ReviewedTransactions'
import type { BudgetPosition } from './lib/budgetPosition'
import type { ComponentProps } from 'react'

afterEach(() => { cleanup(); vi.resetAllMocks() })
const position: BudgetPosition = { id: 1, name: 'Groceries', stackKey: 'discretionary', stackLabel: 'Flexible spending', planned: 100, actual: 0, pending: 900, remaining: 100, active: true }
const plan = {
  year: 2026, months: [{ id: 41, label: 'Nov', starts_on: '2026-11-01', ends_on: '2026-11-30', status: 'open' }],
  monthly_income: { 41: 200 }, monthly_debt_minimums: 20, rows: [{ id: 1, name: 'Groceries', stack_key: 'discretionary', active: true, months: [{ period_id: 41, allocation_id: 1, planned: 100, actual: 0 }], planned_total: 100, actual_total: 0 }],
  pending_transaction_drafts: [], income_sources: [], recent_transactions: [], annual_outlook: { months: [{ period_id: 41, planned_outflow: 120 }], upcoming_spikes: [] },
} as unknown as AnnualBudgetPlan

it.each([[0, '0%', 'Nothing spent against this plan yet.'], [25, '25%', '$75 left in this group.'], [100, '100%', 'Spending has used the full plan.'], [125, '100%', '$25 over the plan.']])('draws confirmed spending %s against its plan without including pending', (actual, value, meaning) => {
  const view = render(<ExpenseStackOverview positions={[{ ...position, actual: Number(actual) }]} />)
  const group = view.container.querySelector('.stack-discretionary') as HTMLElement
  expect(group.querySelector('.ui-track')?.getAttribute('style')).toContain(`--value: ${value}`)
  expect(group.classList.contains('is-over')).toBe(Number(actual) > 100)
  expect(within(group).getByText(meaning)).toBeTruthy()
  expect(within(group).getByText('$100 planned')).toBeTruthy()
  expect(group.textContent).not.toContain('$900 spent')
})
it('omits bars for unknown plan values and never invents a set-aside total', () => {
  const view = render(<ExpenseStackOverview positions={[{ ...position, allocationMissing: true }, { ...position, id: 2, stackKey: 'sinking_expected', actual: 25 }]} />)
  const unknown = view.container.querySelector('.stack-discretionary')!
  expect(unknown.querySelector('.ui-track')).toBeNull()
  expect(unknown.textContent).toContain('Not entered')
  const sinking = view.container.querySelector('.stack-sinking_expected')!
  expect(sinking.textContent).toContain('$25 spent')
  expect(sinking.textContent).not.toMatch(/\$\d.*set aside/)
})
it('distinguishes a zero plan with spending from a zero plan not started', () => {
  const view = render(<ExpenseStackOverview positions={[{ ...position, planned: 0, actual: 25 }]} />)
  expect(view.container.querySelector('.stack-discretionary .ui-track')?.getAttribute('style')).toContain('100%')
  expect(screen.getByText('$25 over the plan.')).toBeTruthy()
})
it('reads the selected period ID, includes debt minimums and never subtracts pending', () => {
  render(<BudgetPlanStrip plan={plan} monthIndex={0} planKnown />)
  expect(screen.getByText('$200')).toBeTruthy()
  expect(screen.getByText('$120')).toBeTruthy()
  expect(screen.getByText('$80')).toBeTruthy()
})
it('keeps unknown income and debt minimums as words, but a confirmed zero as money', () => {
  const view = render(<BudgetPlanStrip plan={{ ...plan, monthly_income: {41: null}, monthly_debt_minimums_known: false }} monthIndex={0} planKnown />)
  expect(screen.getAllByText('Not entered')).toHaveLength(3)
  expect(view.container.textContent).not.toContain('$0')
  view.rerender(<BudgetPlanStrip plan={{ ...plan, monthly_income: {41: 0} }} monthIndex={0} planKnown />)
  expect(screen.getByText('$0')).toBeTruthy()
  expect(screen.getByText('Short of the plan')).toBeTruthy()
})
it('does not show a plan subtotal when a category allocation is missing', () => {
  const missing = { ...plan, rows: plan.rows.map(row => ({ ...row, months: row.months.map(cell => ({...cell, allocation_missing: true})) })) }
  render(<BudgetPlanStrip plan={missing} monthIndex={0} planKnown />)
  expect(screen.getAllByText('Not entered')).toHaveLength(2)
})
it('keeps the inline budget editor dirty and blocks tool and period changes until cancel', () => {
  const dirty = vi.fn()
  render(<AnnualBudgetPlanner {...{plan, isRealWorkspace:true, action:null, error:null, selectedMonthIndex:0, spendingReport:null, spendingReportLoading:false, spendingReportError:null, newCategory:{name:'',stack_key:'discretionary',monthly_amount:'',month_numbers:[11]}, onUnsavedChangesChange:dirty, onBudgetViewChange:vi.fn(), onAskMia:vi.fn(), onReviewTransactions:vi.fn(), onNewCategoryChange:vi.fn(), onCreateCategory:vi.fn(), onSaveIncomeScheduleEntry:vi.fn(), onDeleteIncomeScheduleEntry:vi.fn(), onSaveBudgetEdits:vi.fn(), onArchiveCategory:vi.fn(), onRestoreCategory:vi.fn(), onReopenDraft:vi.fn()} as ComponentProps<typeof AnnualBudgetPlanner>} />)
  fireEvent.click(screen.getByRole('button', {name:'Manage manually'}))
  fireEvent.click(screen.getByRole('button', {name:'Edit monthly plan'}))
  fireEvent.change(screen.getByLabelText('Groceries planned for Nov'), {target:{value:'150'}})
  expect(dirty).toHaveBeenLastCalledWith(true)
  for (const name of ['Close manual tools','Add a category','Schedule income','Previous year','Next year']) expect((screen.getByRole('button',{name}) as HTMLButtonElement).disabled).toBe(true)
  expect((screen.getByLabelText('Report month') as HTMLSelectElement).disabled).toBe(true)
  expect(screen.queryByRole('dialog')).toBeNull()
  fireEvent.click(screen.getByRole('button',{name:/^Cancel$/}))
  expect(dirty).toHaveBeenLastCalledWith(false)
})
it('shows the complete confirmed total even when the returned list is capped at 100', () => {
  const report = {start_on:'2026-11-01',end_on:'2026-11-30',period_label:'November 2026',totals:{actual:12345.67},transactions:Array.from({length:100},()=>({amount:1}))} as SpendingReport
  const view=render(<ReviewConfirmedCard report={report} loading={false} error={null}><p>Reviewed list</p></ReviewConfirmedCard>)
  expect(screen.getByText('$12,345.67')).toBeTruthy()
  expect(view.container.textContent).not.toContain('100 purchases')
  view.rerender(<ReviewConfirmedCard report={report} loading={false} error="Report unavailable">{null}</ReviewConfirmedCard>)
  expect(screen.getByText('Not known yet')).toBeTruthy()
  expect(screen.queryByText('$12,345.67')).toBeNull()
})
it('keeps the header bulk action guarded while a purchase editor is open', () => {
  const drafts = [1,2].map(id=>({id,merchant:`Market ${id}`,occurred_on:'2026-11-01',amount:25,amount_cents:2500,status:'pending',source_type:'manual_ui',category_id:1,category_name:'Groceries',splits:[],matches:[]})) as TransactionDraft[]
  const bulk=vi.fn()
  render(<TransactionDraftReviewStack headerBulkAction drafts={drafts} isRealWorkspace action={null} categories={plan.rows} onUpdate={vi.fn()} onConfirm={vi.fn()} onIgnore={vi.fn()} onReopen={vi.fn()} onBulkConfirm={bulk} onBulkIgnore={vi.fn()} />)
  const action=screen.getByRole('button',{name:'Confirm categorized 2'}) as HTMLButtonElement
  expect(action.disabled).toBe(false)
  fireEvent.click(screen.getByRole('button',{name:'Change Market 1 $25 on Nov 1'}))
  expect(action.disabled).toBe(true)
  expect(bulk).not.toHaveBeenCalled()
})

it('uses the approved current-month answer even when the annual-plan cache differs', () => {
  const answer = {year:2026, month:11, period_label:'November 2026', money_in_cents:520000, planned_out_cents:310000, plan_left_cents:210000, spent_so_far_cents:null, pending_count:null, pending_cents:null, pending_list_truncated:false, readiness_tone:null, readiness_guidance:'', runway_months:null}
  const view = render(<BudgetPlanStrip plan={plan} monthIndex={0} planKnown answer={answer} />)
  for (const value of ['$5,200', '$3,100', '$2,100']) expect(screen.getByText(value)).toBeTruthy()
  view.rerender(<BudgetPlanStrip plan={plan} monthIndex={0} planKnown answer={{ ...answer, money_in_cents:null, planned_out_cents:null, plan_left_cents:null }} />)
  expect(screen.getAllByText('Not entered')).toHaveLength(3)
  expect(view.container.textContent).not.toContain('$0')
})

it('includes imported confirmed spending in See all without offering an unsupported reversal', () => {
  const report = {period_label:'November 2026',transactions:[{id:1,merchant:'Imported rent',occurred_on:'2026-11-01',amount:100,categories:['Rent'],source_type:'import',transaction_draft_id:null}],ignored_drafts:[]} as unknown as SpendingReport
  const onReopen = vi.fn()
  render(<ReviewedTransactionsPanel includeAllConfirmed report={report} action={null} onReopen={onReopen} />)
  expect(screen.getByText('Imported rent')).toBeTruthy()
  expect(screen.getByText('$100')).toBeTruthy()
  expect(screen.queryByRole('button')).toBeNull()
  expect(onReopen).not.toHaveBeenCalled()
})
