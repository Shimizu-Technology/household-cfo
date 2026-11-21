// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { StatementBalanceOffer } from '../api'
import { announceStatementBalanceChange, offerQuestion } from '../lib/statementBalanceOffer'
import { StatementBalanceOffers } from './StatementBalanceOffers'

const apiMocks = vi.hoisted(() => ({
  fetchStatementBalanceOffers: vi.fn(),
  applyStatementBalance: vi.fn(),
}))

vi.mock('../api', async (importOriginal) => ({
  ...await importOriginal<typeof import('../api')>(),
  ...apiMocks,
}))

const checking: StatementBalanceOffer = {
  key: 'a'.repeat(64), tracked_account_id: 7, kind: 'account', statement_label: 'Checking ····6824', as_of_on: '2026-10-31',
  balance: 2413.07, balance_cents: 241_307,
  target: { kind: 'account', id: 11, label: 'Checking ····6824', type: 'checking', balance: 1900, balance_cents: 190_000, balance_as_of_on: null },
  choices: [], can_add_new: false, new_label: null, new_account_type: null, new_type_options: [],
}

const card: StatementBalanceOffer = {
  key: 'b'.repeat(64), tracked_account_id: 8, kind: 'debt', statement_label: 'Mainland Visa ····6074', as_of_on: '2026-10-31',
  balance: 4296.96, balance_cents: 429_696, target: null,
  choices: [{ kind: 'debt', id: 21, label: 'Mainland Visa', type: 'credit_card', balance: 4000, balance_cents: 400_000, balance_as_of_on: null }],
  can_add_new: true, new_label: 'Mainland Visa ····6074', new_account_type: 'credit_card',
  new_type_options: ['credit_card', 'student_loan', 'auto_loan', 'mortgage', 'personal_loan', 'medical', 'other'],
}

beforeEach(() => {
  // Dates in these questions name the year only outside the current one.
  vi.useFakeTimers({ toFake: ['Date'] })
  vi.setSystemTime(new Date('2026-11-21T12:00:00Z'))
  localStorage.clear()
  apiMocks.fetchStatementBalanceOffers.mockReset()
  apiMocks.applyStatementBalance.mockReset()
})
afterEach(() => {
  cleanup()
  vi.useRealTimers()
})

describe('StatementBalanceOffers', () => {
  it('asks one plain question with the statement date and updates only after she approves', async () => {
    apiMocks.fetchStatementBalanceOffers.mockResolvedValueOnce([checking]).mockResolvedValue([])
    apiMocks.applyStatementBalance.mockResolvedValue([])
    const onChanged = vi.fn().mockResolvedValue(undefined)
    render(<StatementBalanceOffers onChanged={onChanged} />)

    expect(await screen.findByText('Update Checking ····6824 to $2,413.07 from your Oct 31 statement?')).toBeTruthy()
    expect(screen.getByText('Now: $1,900')).toBeTruthy()
    expect(apiMocks.applyStatementBalance).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole('button', { name: 'Update balance' }))
    await waitFor(() => expect(apiMocks.applyStatementBalance).toHaveBeenCalledTimes(1))
    const [offer, target, key] = apiMocks.applyStatementBalance.mock.calls[0]
    expect(offer).toBe(checking)
    expect(target).toBe(11)
    expect(typeof key).toBe('string')
    await screen.findByText('Balance updated.')
    expect(onChanged).toHaveBeenCalledTimes(1)
    expect(screen.queryByRole('button', { name: 'Update balance' })).toBeNull()
    // The list that approved it does not ask the server again.
    expect(apiMocks.fetchStatementBalanceOffers).toHaveBeenCalledTimes(1)
  })

  it('Not now changes nothing and keeps that offer hidden', async () => {
    apiMocks.fetchStatementBalanceOffers.mockResolvedValue([checking])
    const onChanged = vi.fn()
    const { unmount } = render(<StatementBalanceOffers onChanged={onChanged} />)
    fireEvent.click(await screen.findByRole('button', { name: 'Not now' }))
    expect(screen.queryByText(/Update Checking/)).toBeNull()
    expect(apiMocks.applyStatementBalance).not.toHaveBeenCalled()
    expect(onChanged).not.toHaveBeenCalled()
    unmount()

    render(<StatementBalanceOffers onChanged={onChanged} />)
    await waitFor(() => expect(apiMocks.fetchStatementBalanceOffers).toHaveBeenCalledTimes(2))
    expect(screen.queryByText(/Update Checking/)).toBeNull()
  })

  it('asks which card a statement belongs to before it can be approved, and says the amount is owed', async () => {
    apiMocks.fetchStatementBalanceOffers.mockResolvedValue([card])
    apiMocks.applyStatementBalance.mockResolvedValue([])
    render(<StatementBalanceOffers onChanged={vi.fn().mockResolvedValue(undefined)} />)

    expect(await screen.findByText('Your Oct 31 statement for Mainland Visa ····6074 shows $4,296.96 owed. Which card is it?')).toBeTruthy()
    const approve = screen.getByRole('button', { name: 'Update balance' }) as HTMLButtonElement
    expect(approve.disabled).toBe(true)

    fireEvent.click(screen.getByLabelText(/Mainland Visa \(\$4,000\)/))
    expect(screen.getByText('Update Mainland Visa to $4,296.96 owed from your Oct 31 statement?')).toBeTruthy()
    fireEvent.click(screen.getByLabelText('Add it as a new card'))
    expect(screen.getByText('Add Mainland Visa ····6074 to your debts with $4,296.96 owed from your Oct 31 statement?')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Add card' }))
    await waitFor(() => expect(apiMocks.applyStatementBalance).toHaveBeenCalledWith(card, 'new', expect.any(String), 'credit_card'))
  })

  it('shows a plain error and changes nothing when the approval cannot be saved', async () => {
    apiMocks.fetchStatementBalanceOffers.mockResolvedValue([checking])
    const stale = Object.assign(new Error('Only checking or savings can have a negative balance. Nothing changed.'), { name: 'ApiRequestError', status: 422 })
    apiMocks.applyStatementBalance.mockRejectedValue(stale)
    const onChanged = vi.fn()
    render(<StatementBalanceOffers onChanged={onChanged} />)
    fireEvent.click(await screen.findByRole('button', { name: 'Update balance' }))
    expect((await screen.findByRole('alert')).textContent).toContain('Nothing changed')
    expect(onChanged).not.toHaveBeenCalled()
  })

  it('asks no account question when the only answer is adding it', async () => {
    apiMocks.fetchStatementBalanceOffers.mockResolvedValue([{ ...card, kind: 'account', choices: [], new_label: 'Checking ····4410', statement_label: 'Checking ····4410', new_account_type: 'checking', new_type_options: ['checking', 'savings'] }])
    render(<StatementBalanceOffers onChanged={vi.fn()} />)
    expect(await screen.findByText('Add Checking ····4410 to My Money with $4,296.96 from your Oct 31 statement?')).toBeTruthy()
    expect(screen.queryByRole('group', { name: 'Which account is this?' })).toBeNull()
    expect((screen.getByRole('button', { name: 'Add account' }) as HTMLButtonElement).disabled).toBe(false)
  })

  it('renders nothing when there is no offer', async () => {
    apiMocks.fetchStatementBalanceOffers.mockResolvedValue([])
    const { container } = render(<StatementBalanceOffers onChanged={vi.fn()} />)
    await waitFor(() => expect(apiMocks.fetchStatementBalanceOffers).toHaveBeenCalled())
    expect(container.textContent).toBe('')
  })

  it('says when offers could not be checked and lets her try again', async () => {
    apiMocks.fetchStatementBalanceOffers.mockRejectedValueOnce(new Error('offline')).mockResolvedValue([checking])
    render(<StatementBalanceOffers onChanged={vi.fn()} />)
    fireEvent.click(await screen.findByRole('button', { name: 'Try again' }))
    expect(await screen.findByText('Update Checking ····6824 to $2,413.07 from your Oct 31 statement?')).toBeTruthy()
  })

  it('waits for an open money edit to be saved or cancelled before approving', async () => {
    apiMocks.fetchStatementBalanceOffers.mockResolvedValue([checking])
    const { rerender } = render(<StatementBalanceOffers onChanged={vi.fn()} blockedReason="Save or cancel your open edit in My Money first." />)
    const approve = await screen.findByRole('button', { name: 'Update balance' }) as HTMLButtonElement
    expect(approve.disabled).toBe(true)
    expect(screen.getByText('Save or cancel your open edit in My Money first.')).toBeTruthy()
    rerender(<StatementBalanceOffers onChanged={vi.fn()} blockedReason={null} />)
    expect((screen.getByRole('button', { name: 'Update balance' }) as HTMLButtonElement).disabled).toBe(false)
  })

  it('keeps Not now for this page even when storage cannot save it, and when a balance changes elsewhere', async () => {
    apiMocks.fetchStatementBalanceOffers.mockResolvedValue([checking])
    const setItem = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('blocked') })
    render(<><StatementBalanceOffers onChanged={vi.fn()} /><div data-testid="second"><StatementBalanceOffers onChanged={vi.fn()} /></div></>)
    await waitFor(() => expect(screen.getAllByRole('button', { name: 'Not now' })).toHaveLength(2))
    fireEvent.click(screen.getAllByRole('button', { name: 'Not now' })[0])
    await waitFor(() => expect(screen.queryAllByRole('button', { name: 'Not now' })).toHaveLength(0))
    setItem.mockRestore()
  })

  it('names the year for a statement from another year', () => {
    expect(offerQuestion({ ...checking, as_of_on: '2025-12-31' }, 11, new Date('2026-11-21T12:00:00Z'))).toBe('Update Checking ····6824 to $2,413.07 from your Dec 31, 2025 statement?')
  })
  it('asks what kind a new loan or account is when the statement does not say, and sends her answer', async () => {
    const loan = { ...card, statement_label: 'Island Finance ····3301', new_label: 'Island Finance ····3301', choices: [], new_account_type: null }
    apiMocks.fetchStatementBalanceOffers.mockResolvedValue([loan])
    apiMocks.applyStatementBalance.mockResolvedValue([])
    render(<StatementBalanceOffers onChanged={vi.fn().mockResolvedValue(undefined)} />)
    const add = await screen.findByRole('button', { name: 'Add card' }) as HTMLButtonElement
    expect(add.disabled).toBe(true)
    fireEvent.change(screen.getByLabelText('What kind of debt is this?'), { target: { value: 'auto_loan' } })
    expect(add.disabled).toBe(false)
    fireEvent.click(add)
    await waitFor(() => expect(apiMocks.applyStatementBalance).toHaveBeenCalledWith(loan, 'new', expect.any(String), 'auto_loan'))
  })

  it('shows the latest offers when an approval is refused because something changed', async () => {
    apiMocks.fetchStatementBalanceOffers.mockResolvedValueOnce([checking]).mockResolvedValue([{ ...checking, key: 'c'.repeat(64), target: { ...checking.target!, balance: 2000, balance_cents: 200_000 } }])
    apiMocks.applyStatementBalance.mockRejectedValue(Object.assign(new Error('Your statements or accounts changed since this was shown. Refresh to see the latest. Nothing changed.'), { name: 'ApiRequestError', status: 409, code: 'stale_review' }))
    render(<StatementBalanceOffers onChanged={vi.fn()} />)
    fireEvent.click(await screen.findByRole('button', { name: 'Update balance' }))
    expect(await screen.findByText('Now: $2,000')).toBeTruthy()
    expect(apiMocks.fetchStatementBalanceOffers).toHaveBeenCalledTimes(2)
    expect(screen.getByRole('status').textContent).toContain('Nothing changed')
  })

  it('moves focus to what happened after an approval', async () => {
    apiMocks.fetchStatementBalanceOffers.mockResolvedValueOnce([checking]).mockResolvedValue([])
    apiMocks.applyStatementBalance.mockResolvedValue([])
    render(<StatementBalanceOffers onChanged={vi.fn().mockResolvedValue(undefined)} />)
    fireEvent.click(await screen.findByRole('button', { name: 'Update balance' }))
    await waitFor(() => expect(document.activeElement?.textContent).toBe('Balance updated.'))
  })

  it('reloads when accounts or debts change elsewhere, and a finished statement shows only its own accounts', async () => {
    apiMocks.fetchStatementBalanceOffers.mockResolvedValue([checking, card])
    render(<StatementBalanceOffers onChanged={vi.fn()} trackedAccountIds={[8]} />)
    expect(await screen.findByText(/Mainland Visa ····6074 shows \$4,296.96 owed/)).toBeTruthy()
    expect(screen.queryByText(/Checking ····6824/)).toBeNull()
    announceStatementBalanceChange()
    await waitFor(() => expect(apiMocks.fetchStatementBalanceOffers).toHaveBeenCalledTimes(2))
  })
})
