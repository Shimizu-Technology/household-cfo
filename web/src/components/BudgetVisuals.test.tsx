// @vitest-environment jsdom
import { cleanup, render } from '@testing-library/react'
import { afterEach, expect, it } from 'vitest'
import { CategoryPressureList, ExpenseStackOverview } from './BudgetVisuals'

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
  const position = { id: 2, name: 'Groceries', stackKey: 'discretionary' as const, stackLabel: 'Flexible spending', planned: 0, actual: 0, pending: 0, remaining: 0, active: true }
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
