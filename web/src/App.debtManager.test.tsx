// @vitest-environment jsdom
import userEvent from '@testing-library/user-event'
import { cleanup, render, screen, within } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { DebtManager } from './App'
import type { DebtPortfolio, DebtRecord } from './api'

// The fictional Talun household's Visa, with a past-due amount Mia applied in another tab.
const visa: DebtRecord = {
  id: 7, label: 'Visa', debt_type: 'credit_card', balance: 1200, minimum_payment: 40, interest_rate_percent: 24.9,
  due_day: null, past_due: null, active: true, archived_at: null, source_type: 'manual_ui', source_metadata: {},
}
const portfolio: DebtPortfolio = { mode: 'individual', total_balance: 1200, monthly_minimum: 40, balance_known: true, minimum_payment_known: true, active_count: 1, archived_count: 0 }
afterEach(() => { cleanup(); vi.restoreAllMocks() })

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}

it('a label edit sends only the label, so an older tab cannot erase a newer past-due amount', async () => {
  const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(jsonResponse({ debt: { ...visa, label: 'Travel Card', past_due: 95.4, due_day: 22 }, debt_portfolio: portfolio }))
  const onChanged = vi.fn().mockResolvedValue(undefined)
  render(<DebtManager debts={[visa]} portfolio={portfolio} onChanged={onChanged} />)

  await userEvent.click(screen.getByRole('button', { name: 'Edit Visa' }))
  const name = screen.getByDisplayValue('Visa')
  await userEvent.clear(name)
  await userEvent.type(name, 'Travel Card')
  await userEvent.click(screen.getByRole('button', { name: 'Save debt' }))

  expect(fetchSpy).toHaveBeenCalledTimes(1)
  const [url, init] = fetchSpy.mock.calls[0]
  expect(String(url)).toContain('/api/v1/debts/7')
  expect(JSON.parse(String((init as RequestInit).body))).toEqual({ debt: { label: 'Travel Card' }, expected: { label: 'Visa' } })
  expect(onChanged).toHaveBeenCalled()
})

it('a refused stale edit reloads the latest details and says so', async () => {
  vi.spyOn(globalThis, 'fetch').mockResolvedValue(jsonResponse({ errors: ['This debt changed in another tab or on another device.'], code: 'changed_elsewhere' }, 409))
  const onChanged = vi.fn().mockResolvedValue(undefined)
  render(<DebtManager debts={[visa]} portfolio={portfolio} onChanged={onChanged} />)

  await userEvent.click(screen.getByRole('button', { name: 'Edit Visa' }))
  await userEvent.type(screen.getByPlaceholderText('Not sure'), '0')
  await userEvent.click(screen.getByRole('button', { name: 'Save debt' }))

  expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'This debt changed in another tab or on another device. The latest details are showing now; open it and make your change again.')
  expect(onChanged).toHaveBeenCalled()
})

it('shows Caught up for an entered $0, the amount when behind, and nothing when not entered', () => {
  render(<DebtManager debts={[
    { ...visa, id: 1, label: 'Visa', past_due: 0 },
    { ...visa, id: 2, label: 'Car loan', debt_type: 'auto_loan', past_due: 1500, due_day: 15 },
    { ...visa, id: 3, label: 'Store card', past_due: null },
  ]} portfolio={portfolio} onChanged={vi.fn()} />)
  const row = (label: string) => screen.getByRole('button', { name: `Edit ${label}` })
  expect(within(row('Visa')).getByText('Caught up')).toBeTruthy()
  expect(within(row('Car loan')).getByText('$1,500 past due')).toBeTruthy()
  expect(within(row('Store card')).queryByText('Caught up')).toBeNull()
  expect(within(row('Store card')).queryByText(/past due/)).toBeNull()
})
