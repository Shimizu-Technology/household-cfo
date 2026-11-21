// @vitest-environment jsdom
import { cleanup, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, expect, it, vi } from 'vitest'
import type { CohortExperienceDraft, StoredMethodSettings } from '../api'
import { MethodSettingsEditor } from '../components/MethodSettingsEditor'
import { ExpenseStackOverview } from '../components/BudgetVisuals'
import { ExpenseGroupNamesContext } from './expenseGroups'
import { defaultMethod, methodChanges, methodOf } from './methodSettings'

afterEach(cleanup)

it('reads a saved method without the display choices as their defaults', () => {
  const stored: StoredMethodSettings = { ...defaultMethod }
  delete stored.group_names
  delete stored.home_view
  delete stored.debt_order
  const draft = { schema_version: 5, experience_mode: 'household_cfo', optional_modules: {}, method: stored } as unknown as CohortExperienceDraft
  expect(methodOf(draft)).toEqual({ ...stored, group_names: 'plain', home_view: 'month', debt_order: 'both' })
  expect(methodOf({ ...draft, method: { ...stored, group_names: 'method' } } as CohortExperienceDraft).group_names).toBe('method')
})

it('names each display choice in the Go live review', () => {
  expect(methodChanges(defaultMethod, { ...defaultMethod, group_names: 'method', home_view: 'year', debt_order: 'snowball' })).toEqual([
    'Method: spending groups are called Non-discretionary, Discretionary, Sinking Fund — Expected, Sinking Fund — Unexpected (her method’s terms).',
    'Method: Home shows the year first. Each person can still switch.',
    'Method: debt payoff starts with snowball.',
  ])
  expect(methodChanges({ ...defaultMethod, debt_order: 'avalanche' }, defaultMethod)).toEqual(['Method: debt payoff shows snowball and avalanche side by side.'])
  expect(methodChanges(defaultMethod, defaultMethod)).toEqual([])
})

it('lets a coach pick each display choice as a single option', async () => {
  const user = userEvent.setup()
  const onChange = vi.fn()
  render(<MethodSettingsEditor method={defaultMethod} disabled={false} onChange={onChange} />)
  const names = screen.getByRole('group', { name: 'Spending group names' })
  expect(within(names).getByRole('radio', { name: /Plain words/ })).toHaveProperty('checked', true)
  expect(within(names).getByText('Must-pay bills, Flexible spending, Planned yearly costs, Surprise fund')).toBeTruthy()
  await user.click(within(names).getByRole('radio', { name: /Her method’s terms/ }))
  expect(onChange).toHaveBeenLastCalledWith({ ...defaultMethod, group_names: 'method' })

  const home = screen.getByRole('group', { name: 'Home leads with' })
  expect(within(home).getByRole('radio', { name: /Month first/ })).toHaveProperty('checked', true)
  await user.click(within(home).getByRole('radio', { name: /Year first/ }))
  expect(onChange).toHaveBeenLastCalledWith({ ...defaultMethod, home_view: 'year' })

  const debt = screen.getByRole('group', { name: 'Debt payoff' })
  expect(within(debt).getByRole('radio', { name: /Show both and let her choose/ })).toHaveProperty('checked', true)
  await user.click(within(debt).getByRole('radio', { name: /Avalanche first/ }))
  expect(onChange).toHaveBeenLastCalledWith({ ...defaultMethod, debt_order: 'avalanche' })
})

it('shows the program’s group names on Budget with the same totals', () => {
  const positions = [
    { id: 1, name: 'Rent', stackKey: 'non_discretionary' as const, stackLabel: 'x', planned: 1500, actual: 1500, pending: 0, remaining: 0, active: true },
    { id: 2, name: 'Eating out', stackKey: 'discretionary' as const, stackLabel: 'x', planned: 200, actual: 50, pending: 0, remaining: 150, active: true },
  ]
  const headings = (container: HTMLElement) => Array.from(container.querySelectorAll('.expense-stack-row-heading')).map(row => row.textContent)
  const plain = render(<ExpenseStackOverview positions={positions} />)
  const plainRows = headings(plain.container)
  expect(plain.container.textContent).toContain('Must-pay bills stay steady. Flexible spending is where you can adjust.')
  expect(plainRows.join(' ')).toContain('Must-pay bills')
  plain.unmount()
  const terms = render(<ExpenseGroupNamesContext.Provider value="method"><ExpenseStackOverview positions={positions} /></ExpenseGroupNamesContext.Provider>)
  const termRows = headings(terms.container)
  expect(terms.container.textContent).toContain('Non-discretionary costs stay steady. Discretionary spending is where you can adjust.')
  expect(termRows.join(' ')).toContain('Non-discretionary')
  expect(termRows.join(' ')).not.toContain('Must-pay bills')
  expect(termRows.map(row => row?.replace(/^[^$]*/, ''))).toEqual(plainRows.map(row => row?.replace(/^[^$]*/, '')))
})
