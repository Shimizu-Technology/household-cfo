// @vitest-environment jsdom
import { cleanup, render } from '@testing-library/react'
import { afterEach, expect, it } from 'vitest'
import { CategoryPressureList, ExpenseStackOverview, MonthPlanSummary } from './BudgetVisuals'

afterEach(cleanup)

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

it('keeps a confirmed zero category plan known when an uncategorized purchase is pending', () => {
  const {container} = render(<ExpenseStackOverview positions={[
    {id:0,name:'Uncategorized',stackKey:'discretionary',stackLabel:'Needs category',planned:0,actual:0,pending:35,remaining:0,active:true},
    {id:2,name:'Everyday spending',stackKey:'discretionary',stackLabel:'Discretionary',planned:0,actual:0,pending:0,remaining:0,active:true},
  ]} />)
  expect(container.querySelector('.stack-discretionary .expense-stack-row-heading b')?.textContent).toBe('$0 planned')
  expect(container.textContent).toContain('$35 pending review')
  expect(container.querySelector('.stack-discretionary .ui-track')).toBeTruthy()
})


it('keeps known zero spending separate from zero plan and a missing allocation', () => {
  const position = { id: 2, name: 'Groceries', neverPlanned: true, stackKey: 'discretionary' as const, stackLabel: 'Flexible spending', planned: 0, actual: 0, pending: 0, remaining: 0, active: true }
  const view = render(<CategoryPressureList positions={[position]} onPlanCategory={() => {}} />)
  expect(view.container.textContent).toContain('$0 actual')
  expect(view.container.textContent).toContain('No amount planned yet')
  view.rerender(<CategoryPressureList positions={[{ ...position, allocationMissing: true }]} onPlanCategory={() => {}} />)
  expect(view.container.textContent).toContain('Planned amount needs repair')
  expect(view.container.textContent).not.toContain('No amount planned yet')
  expect(view.container.querySelector('button')).toBeNull()
  view.rerender(<ExpenseStackOverview positions={[{ ...position, allocationMissing: true }]} onPlanCategory={() => {}} />)
  expect(view.container.querySelector('button')).toBeNull()
})

it('preserves deliberate zero months and unknown spending before the plan starts', () => {
  const position = { id: 2, name: 'Christmas gifts', stackKey: 'sinking_expected' as const, stackLabel: 'Planned yearly costs', planned: 0, actual: 0, pending: 25, remaining: 0, active: true, neverPlanned: false }
  const view = render(<CategoryPressureList positions={[position]} onPlanCategory={() => {}} />)
  expect(view.container.textContent).toContain('$0 planned')
  expect(view.container.textContent).not.toContain('No amount planned yet')
  expect(view.container.querySelector('button')).toBeNull()
  view.rerender(<CategoryPressureList positions={[position]} planKnown={false} />)
  expect(view.container.textContent).toContain('Approved spending not known yet')
  expect(view.container.textContent).not.toContain('$0 actual')
})

it('shows a category month that refunds brought below zero as it is, never as $0 or unknown', () => {
  const position = { id: 5, name: 'Clothing', stackKey: 'discretionary' as const, stackLabel: 'Flexible spending', planned: 100, actual: -110, pending: 0, remaining: 210, active: true }
  const view = render(<CategoryPressureList positions={[position]} />)
  expect(view.container.textContent).toContain('-$110 actual')
  expect(view.container.textContent).toContain('$210 remaining now')
  expect(view.container.textContent).toContain('More came back in refunds this month than was spent.')
  view.rerender(<CategoryPressureList positions={[position]} planKnown={false} />)
  expect(view.container.textContent).toContain('-$110 actual')
  expect(view.container.textContent).not.toContain('Approved spending not known yet')
  view.rerender(<ExpenseStackOverview positions={[{ ...position, active: false }]} />)
  const flexible = view.container.querySelector('.stack-discretionary')!.textContent
  expect(flexible).toContain('-$110 after refunds')
  expect(flexible).toContain('-$110 after refunds · archived')
  expect(flexible).not.toContain('No confirmed transactions yet')
})

it('shows a month whose refunds outweigh its spending as a known negative amount', () => {
  const view = render(<MonthPlanSummary label="March 2026" income={5000} planned={1000} actual={-29.99} pending={0} />)
  expect(view.container.textContent).toContain('-$29.99')
  expect(view.container.textContent).not.toContain('No confirmed transactions yet')
  expect(view.container.textContent).toContain('More came back in refunds this month than was spent.')
})

it('a group or category whose purchases and refunds cancel out is a known $0, not "no transactions"', () => {
  const position = { id: 7, name: 'Clothing', stackKey: 'discretionary' as const, stackLabel: 'Flexible spending', planned: 100, actual: 0, pending: 0, remaining: 100, active: true, hasActivity: true }
  const group = render(<ExpenseStackOverview positions={[position]} />)
  const flexible = group.container.querySelector('.stack-discretionary') as HTMLElement
  expect(flexible.textContent).toContain('$0 spent after refunds')
  expect(flexible.textContent).toContain('$100 left in this group.')
  expect(flexible.textContent).not.toContain('No confirmed transactions yet')
  expect(flexible.textContent).not.toContain('Nothing spent against this plan yet.')
  group.unmount()
  const noPlan = render(<CategoryPressureList positions={[position]} planKnown={false} />)
  expect(noPlan.container.textContent).toContain('$0 actual')
  expect(noPlan.container.textContent).not.toContain('Approved spending not known yet')
  noPlan.unmount()
  const quiet = render(<ExpenseStackOverview positions={[{ ...position, hasActivity: false }]} />)
  expect((quiet.container.querySelector('.stack-discretionary') as HTMLElement).textContent).toContain('No confirmed transactions yet')
})

it('an archived category whose purchases and refunds cancel out still shows in its group as a known $0', () => {
  const position = { id: 8, name: 'Old hobby', stackKey: 'discretionary' as const, stackLabel: 'Flexible spending', planned: 40, actual: 0, pending: 0, remaining: 40, active: false, hasActivity: true }
  const view = render(<ExpenseStackOverview positions={[position]} />)
  const flexible = view.container.querySelector('.stack-discretionary') as HTMLElement
  expect(flexible.textContent).toContain('Old hobby')
  expect(flexible.textContent).toContain('$0 after refunds · archived')
  expect(flexible.textContent).toContain('$0 spent after refunds')
  expect(flexible.textContent).toContain('Purchases and refunds cancelled out.')
  expect(flexible.textContent).not.toContain('No confirmed transactions yet')
  expect(flexible.textContent).not.toContain('Spending has used the full plan.')
  view.unmount()
  // An archived category with nothing this month stays out of the group.
  const quiet = render(<ExpenseStackOverview positions={[{ ...position, hasActivity: false }]} />)
  const quietGroup = quiet.container.querySelector('.stack-discretionary') as HTMLElement
  expect(quietGroup.textContent).not.toContain('Old hobby')
  expect(quietGroup.textContent).toContain('No confirmed transactions yet')
})
