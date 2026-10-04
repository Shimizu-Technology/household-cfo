// @vitest-environment jsdom

import { act, cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useState } from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AccountRecord, AssetPortfolio } from '../api'
import { AccountManager } from './AccountManager'
import { accountSummaryText } from './accountSummary'

const apiMocks = vi.hoisted(() => ({
  fetchPlaidOverview: vi.fn(),
  createAccount: vi.fn(),
  updateAccount: vi.fn(),
  archiveAccount: vi.fn(),
  restoreAccount: vi.fn(),
  linkPlaidAccount: vi.fn(),
  reconcilePlaidAccount: vi.fn(),
  unlinkPlaidAccount: vi.fn(),
}))

vi.mock('../api', async (importOriginal) => ({
  ...await importOriginal<typeof import('../api')>(),
  ...apiMocks,
}))

const portfolio: AssetPortfolio = {
  liquid_balance: 0,
  nonliquid_balance: 0,
  total_balance: 0,
  liquid_balance_known: false,
  nonliquid_balance_known: false,
  total_balance_known: false,
  active_count: 1,
  archived_count: 0,
  liquid_known_count: 0,
  nonliquid_known_count: 0,
  total_known_count: 0,
  unknown_balance_account_ids: [1],
}

function account(overrides: Partial<AccountRecord> = {}): AccountRecord {
  return {
    id: 1,
    label: 'Everyday checking',
    account_type: 'checking',
    balance: null,
    balance_as_of_on: null,
    active: true,
    archived_at: null,
    source_type: 'manual_ui',
    source_metadata: {},
    plaid_link: null,
    ...overrides,
  }
}

describe('AccountManager', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    apiMocks.fetchPlaidOverview.mockResolvedValue({ configured: true, environment: 'sandbox', consent_policy_version: 'test', items: [] })
    Object.defineProperty(HTMLElement.prototype, 'scrollIntoView', { configurable: true, value: vi.fn() })
    vi.stubGlobal('requestAnimationFrame', (callback: FrameRequestCallback) => window.setTimeout(() => callback(0), 0))
  })

  afterEach(() => {
    cleanup()
    vi.unstubAllGlobals()
  })

  it('distinguishes no entered subtotal from confirmed zero', () => {
    expect(accountSummaryText(0, false, 0, 1)).toBe('Needs a balance')
    expect(accountSummaryText(0, false, 0, 0)).toBe('Not entered')
    expect(accountSummaryText(0, true, 1, 1)).toBe('$0.00')
    expect(accountSummaryText(125, false, 1, 2)).toBe('$125.00 known so far')
  })

  it('shows inactive bank guidance, disables reconciliation, and surfaces Plaid load failures', async () => {
    apiMocks.fetchPlaidOverview.mockRejectedValue(new Error('offline'))
    const linked = account({
      balance: 100,
      plaid_link: {
        plaid_account_id: 8,
        institution_name: 'Island Bank',
        name: 'Checking',
        mask: '1234',
        current_balance: 120,
        available_balance: 110,
        observed_at: '2026-10-01T00:00:00Z',
        active: false,
        observation_newer_than_saved: true,
      },
    })

    render(<AccountManager accounts={[linked]} portfolio={{ ...portfolio, liquid_known_count: 1 }} onChanged={vi.fn()} />)

    expect(await screen.findByText(/Reconnect or sync this institution/)).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Accept bank balance' }).hasAttribute('disabled')).toBe(true)
    expect(screen.getByRole('button', { name: 'Unmatch' })).toBeTruthy()
    expect(await screen.findByText(/Bank connections could not load/)).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Retry bank connections' })).toBeTruthy()
  })

  it('focuses an invalid balance and restores focus when editing is canceled', async () => {
    const user = userEvent.setup()
    render(<AccountManager accounts={[]} portfolio={{ ...portfolio, active_count: 0, unknown_balance_account_ids: [] }} onChanged={vi.fn()} />)

    const add = screen.getByRole('button', { name: 'Add an account' })
    await user.click(add)
    await user.type(screen.getByPlaceholderText('Everyday checking'), 'Brokerage')
    await user.selectOptions(screen.getByLabelText('Type'), 'investment')
    const balance = screen.getByPlaceholderText('Unknown')
    await user.type(balance, '-5')
    await user.click(screen.getByRole('button', { name: 'Add account' }))

    expect((await screen.findByRole('alert')).textContent).toMatch(/Only checking and savings/)
    expect(document.activeElement).toBe(balance)

    await user.clear(balance)
    await user.click(screen.getByRole('button', { name: 'Cancel' }))
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Add an account' })))
  })

  it('reports a committed write separately when the workspace refresh fails', async () => {
    const user = userEvent.setup()
    apiMocks.createAccount.mockResolvedValue(account({ id: 42, label: 'Savings', account_type: 'savings', balance: 0 }))
    const onChanged = vi.fn().mockRejectedValue(new Error('refresh failed'))
    render(<AccountManager accounts={[]} portfolio={{ ...portfolio, active_count: 0, unknown_balance_account_ids: [] }} onChanged={onChanged} />)

    await user.click(screen.getByRole('button', { name: 'Add an account' }))
    await user.type(screen.getByPlaceholderText('Everyday checking'), 'Savings')
    await user.selectOptions(screen.getByLabelText('Type'), 'savings')
    await user.type(screen.getByPlaceholderText('Unknown'), '0')
    await user.click(screen.getByRole('button', { name: 'Add account' }))

    expect(await screen.findByText(/change was saved, but the latest account list could not reload/)).toBeTruthy()
    expect(screen.queryByText(/could not be saved/)).toBeNull()
    expect(apiMocks.createAccount).toHaveBeenCalledOnce()
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Add an account' })))
  })

  it('opens the exact account editor requested by a Mia review item', async () => {
    const first = account({ id: 1, label: 'Checking' })
    const second = account({ id: 2, label: 'Emergency reserve', account_type: 'emergency_fund' })
    const handled = vi.fn()

    render(<AccountManager
      accounts={[first, second]}
      portfolio={{ ...portfolio, active_count: 2, unknown_balance_account_ids: [1, 2] }}
      onChanged={vi.fn()}
      focusRequest={{ key: 1, actionType: 'update_account', accountId: 2, payload: {} }}
      onFocusRequestHandled={handled}
    />)

    const input = await screen.findByDisplayValue('Emergency reserve')
    await waitFor(() => expect(document.activeElement).toBe(input))
    expect(handled).toHaveBeenCalledOnce()
  })

  it('opens archived accounts and focuses restore when Mia requests an archived edit', async () => {
    const archived = account({ id: 7, label: 'Old checking', active: false, archived_at: '2026-09-01T00:00:00Z' })
    const handled = vi.fn()

    render(<AccountManager
      accounts={[archived]}
      portfolio={{ ...portfolio, active_count: 0, archived_count: 1, unknown_balance_account_ids: [] }}
      onChanged={vi.fn()}
      focusRequest={{ key: 2, actionType: 'update_account', accountId: 7, payload: {} }}
      onFocusRequestHandled={handled}
    />)

    const restore = await screen.findByRole('button', { name: 'Restore' })
    await waitFor(() => expect(document.activeElement).toBe(restore))
    expect(restore.closest('details')?.open).toBe(true)
    expect(handled).toHaveBeenCalledOnce()
  })

  it('prefills only proposed account fields and preserves explicit unknown values', async () => {
    render(<AccountManager
      accounts={[account({ id: 2, label: 'Emergency reserve', account_type: 'emergency_fund', balance: 900, balance_as_of_on: '2026-09-01' })]}
      portfolio={{ ...portfolio, active_count: 1 }}
      onChanged={vi.fn()}
      focusRequest={{ key: 3, actionType: 'update_account', accountId: 2, payload: { balance_known: false, balance_cents: 0, balance_as_of_on: null } }}
    />)

    expect((await screen.findByLabelText('Account name') as HTMLInputElement).value).toBe('Emergency reserve')
    expect((screen.getByLabelText('Type') as HTMLSelectElement).value).toBe('emergency_fund')
    expect((document.querySelector('.account-form input[placeholder="Unknown"]') as HTMLInputElement).value).toBe('')
    expect((screen.getByLabelText('Balance date') as HTMLInputElement).value).toBe('')
  })

  it('uses the household date when adding a bank observation', async () => {
    const user = userEvent.setup()
    vi.setSystemTime(new Date('2026-10-01T15:30:00Z'))
    apiMocks.fetchPlaidOverview.mockResolvedValue({
      configured: true,
      environment: 'sandbox',
      consent_policy_version: 'test',
      items: [{
        id: 9,
        institution_name: 'Island Bank',
        status: 'active',
        environment: 'sandbox',
        consented_at: '2026-10-01T00:00:00Z',
        last_synced_at: '2026-10-01T15:30:00Z',
        health: {},
        error_message: null,
        disconnected_at: null,
        auto_confirm_trusted_merchants: false,
        accounts: [{
          id: 12,
          name: 'Everyday',
          official_name: null,
          mask: '1234',
          type: 'depository',
          subtype: 'checking',
          current_balance_cents: 125_00,
          available_balance_cents: 120_00,
          currency: 'USD',
          active: true,
          eligible_for_asset_tracking: true,
          allowed_account_types: ['checking', 'savings'],
          suggested_account_type: 'checking',
          canonical_account_id: null,
          canonical_balance_known: null,
          canonical_balance_cents: null,
          observation_newer_than_saved: true,
        }],
      }],
    })
    render(<AccountManager accounts={[]} portfolio={{ ...portfolio, active_count: 0, unknown_balance_account_ids: [] }} onChanged={vi.fn()} />)

    await user.click(await screen.findByRole('button', { name: 'Review and add' }))

    expect((screen.getByLabelText('Balance date') as HTMLInputElement).value).toBe('2026-10-02')
  })

  it.each(['accept_observed', 'keep_saved'] as const)('returns focus after %s when bank reconciliation renders later', async (decision) => {
    const user = userEvent.setup()
    const original = account({ balance: 100, plaid_link: {
      plaid_account_id: 8, institution_name: 'Island Bank', name: 'Checking', mask: '1234',
      current_balance: 120, available_balance: 110, observed_at: '2026-10-01T00:00:00Z',
      active: true, observation_newer_than_saved: true,
    } })
    const reconciled = { ...original, plaid_link: { ...original.plaid_link!, observation_newer_than_saved: false } }
    apiMocks.reconcilePlaidAccount.mockResolvedValue(reconciled)
    const onChanged = vi.fn().mockResolvedValue(undefined)
    const view = render(<AccountManager accounts={[original]} portfolio={portfolio} onChanged={onChanged} />)
    await user.click(screen.getByRole('button', { name: decision === 'accept_observed' ? 'Accept bank balance' : 'Keep saved' }))
    await waitFor(() => expect(onChanged).toHaveBeenCalledOnce())
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Edit' })))
    view.rerender(<AccountManager accounts={[reconciled]} portfolio={portfolio} onChanged={onChanged} />)
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Edit' }))
    expect(apiMocks.reconcilePlaidAccount).toHaveBeenCalledWith(1, decision, expect.any(String))
  })

  it('waits for the committed bank match before focusing its unmatch control', async () => {
    const user = userEvent.setup()
    apiMocks.fetchPlaidOverview.mockResolvedValue({ items: [{ id: 9, institution_name: 'Island Bank', accounts: [{
      id: 8, name: 'Checking', active: true, eligible_for_asset_tracking: true,
      canonical_account_id: null, allowed_account_types: ['checking'], mask: '1234', current_balance_cents: 120_00,
    }] }] })
    const original = account({ balance: 100 })
    const linked = { ...original, plaid_link: {
      plaid_account_id: 8, institution_name: 'Island Bank', name: 'Checking', mask: '1234',
      current_balance: 120, available_balance: 110, observed_at: '2026-10-01T00:00:00Z',
      active: true, observation_newer_than_saved: true,
    } }
    apiMocks.linkPlaidAccount.mockResolvedValue(linked)
    const onChanged = vi.fn().mockResolvedValue(undefined)
    const view = render(<AccountManager accounts={[original]} portfolio={portfolio} onChanged={onChanged} />)
    const selector = await screen.findByRole('combobox', { name: 'Match a bank observation' })
    await user.selectOptions(selector, '8')
    await waitFor(() => expect(onChanged).toHaveBeenCalledOnce())
    view.rerender(<AccountManager accounts={[linked]} portfolio={portfolio} onChanged={onChanged} />)
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Unmatch' })))
    expect(apiMocks.linkPlaidAccount).toHaveBeenCalledWith(1, 8, expect.any(String))
  })

  it('waits for the committed bank unmatch before focusing the match selector', async () => {
    const user = userEvent.setup()
    apiMocks.fetchPlaidOverview.mockResolvedValue({ items: [{ id: 9, institution_name: 'Island Bank', accounts: [{
      id: 8, name: 'Checking', active: true, eligible_for_asset_tracking: true,
      canonical_account_id: null, allowed_account_types: ['checking'], mask: '1234', current_balance_cents: 120_00,
    }] }] })
    const original = account({ balance: 100, plaid_link: {
      plaid_account_id: 8, institution_name: 'Island Bank', name: 'Checking', mask: '1234',
      current_balance: 120, available_balance: 110, observed_at: '2026-10-01T00:00:00Z',
      active: true, observation_newer_than_saved: false,
    } })
    const unlinked = { ...original, plaid_link: null }
    apiMocks.unlinkPlaidAccount.mockResolvedValue(unlinked)
    const onChanged = vi.fn().mockResolvedValue(undefined)
    const view = render(<AccountManager accounts={[original]} portfolio={portfolio} onChanged={onChanged} />)
    await user.click(screen.getByRole('button', { name: 'Unmatch' }))
    await waitFor(() => expect(onChanged).toHaveBeenCalledOnce())
    view.rerender(<AccountManager accounts={[unlinked]} portfolio={portfolio} onChanged={onChanged} />)
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('combobox', { name: 'Match a bank observation' })))
    expect(apiMocks.unlinkPlaidAccount).toHaveBeenCalledWith(1, expect.any(String))
  })

  it('preserves focus deliberately moved to another field while the updated list is pending', async () => {
    const user = userEvent.setup()
    const original = account()
    const archived = { ...original, active: false, archived_at: '2026-10-02T00:00:00Z' }
    apiMocks.archiveAccount.mockResolvedValue(archived)
    const onChanged = vi.fn().mockResolvedValue(undefined)
    const view = render(<><input aria-label="Household note" /><AccountManager accounts={[original]} portfolio={portfolio} onChanged={onChanged} /></>)
    await user.click(screen.getByRole('button', { name: 'Archive' }))
    await user.click(screen.getByRole('button', { name: 'Confirm archive' }))
    await waitFor(() => expect(onChanged).toHaveBeenCalledOnce())
    await act(async () => { await new Promise<void>((resolve) => window.requestAnimationFrame(() => resolve())) })
    const note = screen.getByRole('textbox', { name: 'Household note' })
    await user.click(note)
    await user.type(note, 'Continue planning')

    view.rerender(<><input aria-label="Household note" /><AccountManager accounts={[archived]} portfolio={{ ...portfolio, active_count: 0, archived_count: 1 }} onChanged={onChanged} /></>)
    await act(async () => { await new Promise<void>((resolve) => window.requestAnimationFrame(() => resolve())) })
    expect(document.activeElement).toBe(note)
    expect((view.container.querySelector('details.debt-archive') as HTMLDetailsElement).open).toBe(false)
    expect(apiMocks.archiveAccount).toHaveBeenCalledOnce()
  })

  it('preserves a second row archive confirmation while the first archive list is pending', async () => {
    const user = userEvent.setup()
    const first = account({ id: 1, label: 'First record' })
    const second = account({ id: 2, label: 'Second record' })
    const firstArchived = { ...first, active: false, archived_at: '2026-10-02T00:00:00Z' }
    const secondArchived = { ...second, active: false, archived_at: '2026-10-02T00:00:00Z' }
    apiMocks.archiveAccount.mockResolvedValueOnce(firstArchived).mockResolvedValueOnce(secondArchived)
    const onChanged = vi.fn().mockResolvedValue(undefined)
    const view = render(<AccountManager accounts={[first, second]} portfolio={{ ...portfolio, active_count: 2 }} onChanged={onChanged} />)
    await user.click(view.container.querySelector<HTMLButtonElement>('[data-account-id="1"] [data-account-action="archive"]')!)
    await user.click(screen.getByRole('button', { name: 'Confirm archive' }))
    await waitFor(() => expect(onChanged).toHaveBeenCalledOnce())
    await act(async () => { await new Promise<void>((resolve) => window.requestAnimationFrame(() => resolve())) })

    // Starting another confirmation remembers a new trigger, but must not change
    // the earlier pending action's permission to move focus.
    await user.click(view.container.querySelector<HTMLButtonElement>('[data-account-id="2"] [data-account-action="archive"]')!)
    const secondConfirmation = screen.getByRole('button', { name: 'Confirm archive' })
    expect(document.activeElement).toBe(secondConfirmation)
    view.rerender(<AccountManager accounts={[firstArchived, second]} portfolio={{ ...portfolio, active_count: 1, archived_count: 1 }} onChanged={onChanged} />)
    await act(async () => { await new Promise<void>((resolve) => window.requestAnimationFrame(() => resolve())) })
    expect(document.activeElement).toBe(secondConfirmation)
    expect((view.container.querySelector('details.debt-archive') as HTMLDetailsElement).open).toBe(false)
    expect(apiMocks.archiveAccount).toHaveBeenCalledOnce()

    // The newly confirmed action still receives its own return-focus request.
    await user.click(secondConfirmation)
    await waitFor(() => expect(onChanged).toHaveBeenCalledTimes(2))
    view.rerender(<AccountManager accounts={[firstArchived, secondArchived]} portfolio={{ ...portfolio, active_count: 0, archived_count: 2 }} onChanged={onChanged} />)
    await waitFor(() => expect(document.activeElement).toBe(view.container.querySelector('[data-account-id="2"] [data-account-action="restore"]')))
    expect(apiMocks.archiveAccount).toHaveBeenCalledTimes(2)
  })

  it('waits for archived and restored account lists to commit before returning focus', async () => {
    const user = userEvent.setup()
    const original = account({ balance: 125, balance_as_of_on: '2026-10-01' })
    const archived = { ...original, active: false, archived_at: '2026-10-02T00:00:00Z' }
    apiMocks.archiveAccount.mockResolvedValue(archived)
    apiMocks.restoreAccount.mockResolvedValue(original)
    const onChanged = vi.fn().mockResolvedValue(undefined)
    const view = render(<AccountManager accounts={[original]} portfolio={portfolio} onChanged={onChanged} />)

    await user.click(screen.getByRole('button', { name: 'Archive' }))
    await user.click(screen.getByRole('button', { name: 'Confirm archive' }))
    await waitFor(() => expect(onChanged).toHaveBeenCalledOnce())
    // The refresh Promise can resolve before React commits its parent update.
    // Let the original one-shot focus frame run against the previous account DOM.
    await act(async () => { await new Promise<void>((resolve) => window.requestAnimationFrame(() => resolve())) })
    expect(screen.queryByRole('button', { name: 'Restore' })).toBeNull()

    view.rerender(<AccountManager accounts={[archived]} portfolio={{ ...portfolio, active_count: 0, archived_count: 1 }} onChanged={onChanged} />)
    const restore = await screen.findByRole('button', { name: 'Restore' })
    await waitFor(() => expect(document.activeElement).toBe(restore))
    expect(restore.closest('details')?.open).toBe(true)
    await user.click(restore)
    await waitFor(() => expect(onChanged).toHaveBeenCalledTimes(2))
    await act(async () => { await new Promise<void>((resolve) => window.requestAnimationFrame(() => resolve())) })
    expect(screen.queryByRole('button', { name: 'Edit' })).toBeNull()
    view.rerender(<AccountManager accounts={[original]} portfolio={portfolio} onChanged={onChanged} />)
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Edit' })))
    expect(apiMocks.archiveAccount).toHaveBeenCalledOnce()
    expect(apiMocks.restoreAccount).toHaveBeenCalledOnce()
  })

  it('restores focus across save, archive, and restore rerenders', async () => {
    const user = userEvent.setup()
    const original = account({ balance: 125, balance_as_of_on: '2026-10-01' })
    apiMocks.updateAccount.mockResolvedValue({ ...original, label: 'Main checking' })
    apiMocks.archiveAccount.mockResolvedValue({ ...original, label: 'Main checking', active: false, archived_at: '2026-10-02T00:00:00Z' })
    apiMocks.restoreAccount.mockResolvedValue({ ...original, label: 'Main checking' })

    function StatefulManager() {
      const [records, setRecords] = useState([original])
      const [nextChange, setNextChange] = useState<'save' | 'archive' | 'restore'>('save')
      async function refresh() {
        if (nextChange === 'save') {
          setRecords((current) => current.map((record) => ({ ...record, label: 'Main checking' })))
          setNextChange('archive')
        } else if (nextChange === 'archive') {
          setRecords((current) => current.map((record) => ({ ...record, active: false, archived_at: '2026-10-02T00:00:00Z' })))
          setNextChange('restore')
        } else {
          setRecords((current) => current.map((record) => ({ ...record, active: true, archived_at: null })))
        }
      }
      return <AccountManager accounts={records} portfolio={{ ...portfolio, liquid_balance: 125, liquid_balance_known: true, total_balance: 125, total_balance_known: true, liquid_known_count: 1, total_known_count: 1 }} onChanged={refresh} />
    }

    render(<StatefulManager />)
    await user.click(screen.getByRole('button', { name: 'Edit' }))
    const name = screen.getByLabelText('Account name')
    await user.clear(name)
    await user.type(name, 'Main checking')
    await user.click(screen.getByRole('button', { name: 'Save account' }))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Edit' })).toBe(document.activeElement))

    await user.click(screen.getByRole('button', { name: 'Archive' }))
    await user.click(screen.getByRole('button', { name: 'Confirm archive' }))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Restore' })).toBe(document.activeElement))

    await user.click(screen.getByRole('button', { name: 'Restore' }))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Edit' })).toBe(document.activeElement))
  })
})
