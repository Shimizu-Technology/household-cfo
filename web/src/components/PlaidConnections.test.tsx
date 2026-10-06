// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { PlaidConnections } from './PlaidConnections'
import * as api from '../api'
import { savePlaidOAuthSession } from '../lib/plaidOAuthSession'
const mocks = vi.hoisted(() => ({ epoch: 0, financialGeneration: 1, open: vi.fn(), link: null as null | { onSuccess: (token: string, metadata: object) => Promise<void> } }))
vi.mock('react-plaid-link', () => ({ usePlaidLink: (config: typeof mocks.link) => { mocks.link = config; return { open: mocks.open, ready: true } } }))
vi.mock('../contexts/brandContextValue', () => ({ useBrand: () => ({ brand: { organization_name: 'QA', product_name: 'Household CFO', footer: {} }, assistantName: 'Mia' }) }))
vi.mock('../api', async original => ({ ...await original<typeof import('../api')>(),
  captureApiOperation: () => { const epoch = mocks.epoch; return () => { if (epoch !== mocks.epoch) throw new Error('Workspace changed') } },
  getApiFinancialGeneration: () => mocks.financialGeneration,
  fetchPlaidOverview: vi.fn(), fetchPlaidTransactions: vi.fn(), createPlaidLinkToken: vi.fn(), createPlaidUpdateLinkToken: vi.fn(), exchangePlaidPublicToken: vi.fn(), resumePlaidItemFinancialPicture: vi.fn(), syncPlaidItem: vi.fn(), disconnectPlaidItem: vi.fn(), updatePlaidItemPreferences: vi.fn(), stagePlaidTransactions: vi.fn(), ignorePlaidTransactions: vi.fn(),
}))
const item: api.PlaidItem = { id: 3, financial_generation: 0, context_paused_by_restart: true, institution_name: 'QA Bank', status: 'active', environment: 'sandbox', consented_at: '', last_synced_at: '2026-10-01T00:00:00Z', health: { state: 'healthy', label: 'Connected', message: 'Ready', requires_attention: false, last_successful_update_at: null, stale_after: '' }, error_message: null, disconnected_at: null, auto_confirm_trusted_merchants: false, accounts: [] }
const overview: api.PlaidOverview = { configured: true, environment: 'sandbox', consent_policy_version: '1', items: [item] }
const summary: api.PlaidActivitySummary = { all_count: 1, posted_outflow_count: 1, posted_outflow_cents: 2000, pending_count: 0, pending_cents: 0, inflow_count: 0, inflow_cents: 0, needs_review_count: 1, needs_review_cents: 2000, confirmed_count: 0, confirmed_actual_count: 0, confirmed_cents: 0, excluded_count: 0 }
const transaction: api.PlaidTransaction = { id: 22, account_id: 4, account_name: 'QA Checking', account_mask: null, name: 'QA Grocery', merchant_name: null, occurred_on: '2026-10-01', authorized_on: null, amount_cents: 2000, pending: false, direction: 'outflow', primary_category: null, detailed_category: null, review_status: 'unreviewed', stageable: true, transaction_draft_id: null, transaction_draft_status: null, confirmed_transaction_id: null, confirmed_amount_cents: null, category_names: [], trust_state: 'bank_observed', removed: false, source_changed_after_draft: false }
function page(transactions: api.PlaidTransaction[] = []) { return { transactions, pagination: { page: 1, per_page: 50, total: transactions.length, has_more: false }, summary } }
beforeEach(() => {
  vi.clearAllMocks(); mocks.epoch = 0; mocks.financialGeneration = 1; mocks.link = null
  localStorage.clear(); window.history.replaceState({}, '', '/')
  Object.assign(window, { Plaid: {} })
  vi.mocked(api.fetchPlaidOverview).mockResolvedValue(overview)
  vi.mocked(api.fetchPlaidTransactions).mockResolvedValue(page())
})
afterEach(cleanup)
async function connect() {
  await screen.findByText('QA Bank')
  fireEvent.click(screen.getByRole('checkbox'))
  fireEvent.click(screen.getByRole('button', { name: 'Connect a bank' }))
}
test('retained connection is paused, hides old balances, disables sync and automation, but permits disconnect', async () => {
  render(<PlaidConnections userId="42" householdId={12} onDraftsCreated={vi.fn()} />)
  await screen.findByText('QA Bank')
  expect(screen.getByRole('button', { name: 'Sync now' })).toHaveProperty('disabled', true)
  expect(screen.getByRole('switch')).toHaveProperty('disabled', true)
  expect(screen.getByRole('button', { name: 'Disconnect' })).toHaveProperty('disabled', false)
  expect(screen.getByText(/Paused after starting over/)).toBeTruthy()
})
test('cancel changes nothing; explicit accepted resume uses reviewed old generation and starts fresh sync with automation off', async () => {
  const resumed = { ...overview, items: [{ ...item, financial_generation: 1, context_paused_by_restart: false, financial_resumed_at: '2026-10-06T00:00:00Z' }] }
  vi.mocked(api.resumePlaidItemFinancialPicture).mockResolvedValue(resumed)
  vi.mocked(api.syncPlaidItem).mockResolvedValue(resumed)
  render(<PlaidConnections userId="42" householdId={12} onDraftsCreated={vi.fn()} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Use new bank activity' }))
  fireEvent.click(screen.getByRole('button', { name: 'Keep paused' })); expect(api.resumePlaidItemFinancialPicture).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Use new bank activity' }))
  const dialog = screen.getByRole('dialog')
  expect(dialog.querySelector<HTMLButtonElement>('.primary-button')!.disabled).toBe(true)
  fireEvent.click(screen.getByLabelText('I want new activity from this bank included in my new financial picture.'))
  fireEvent.click(dialog.querySelector<HTMLButtonElement>('.primary-button')!)
  await waitFor(() => expect(api.syncPlaidItem).toHaveBeenCalledWith(3))
  expect(api.resumePlaidItemFinancialPicture).toHaveBeenCalledWith(3, 0)
  expect(api.updatePlaidItemPreferences).not.toHaveBeenCalled()
  expect(screen.queryByRole('dialog')).toBeNull()
})
test('History uses its own server scope and cannot select or stage even malformed stageable rows', async () => {
  vi.mocked(api.fetchPlaidTransactions).mockImplementation(async (_page, _view, filters) => page(filters?.picture === 'history' ? [transaction] : []))
  render(<PlaidConnections userId="42" householdId={12} variant="activity" onDraftsCreated={vi.fn()} />)
  await screen.findByRole('button', { name: 'History' })
  fireEvent.click(screen.getByRole('button', { name: 'History' }))
  await screen.findByText('QA Grocery')
  expect(api.fetchPlaidTransactions).toHaveBeenLastCalledWith(1, 'all', expect.objectContaining({ picture: 'history' }))
  expect(screen.queryByRole('checkbox', { name: 'Select QA Grocery' })).toBeNull()
  expect(screen.queryByRole('button', { name: /Prepare .* for review/ })).toBeNull()
  expect(api.stagePlaidTransactions).not.toHaveBeenCalled(); expect(api.ignorePlaidTransactions).not.toHaveBeenCalled()
})
test('a Link token reply after reset cannot launch SDK or save a session in the new context', async () => {
  let resolve!: (value: { link_token: string; consent_policy_version: string }) => void
  vi.mocked(api.createPlaidLinkToken).mockImplementation(() => new Promise(done => { resolve = done }))
  render(<PlaidConnections userId="42" householdId={12} onDraftsCreated={vi.fn()} />)
  await connect(); mocks.epoch += 1; mocks.financialGeneration += 1
  await act(async () => resolve({ link_token: 'link-sandbox-qa', consent_policy_version: '1' }))
  expect(mocks.open).not.toHaveBeenCalled(); expect(api.exchangePlaidPublicToken).not.toHaveBeenCalled()
  expect(localStorage.getItem('household-cfo:plaid-oauth:v1')).toBeNull()
})
test.each(['reset', 'unmount'])('delayed SDK callback cannot exchange in a fresh context after %s', async reason => {
  vi.mocked(api.createPlaidLinkToken).mockResolvedValue({ link_token: 'link-sandbox-qa', consent_policy_version: '1' })
  const view = render(<PlaidConnections userId="42" householdId={12} onDraftsCreated={vi.fn()} />)
  await connect(); await waitFor(() => expect(mocks.link).not.toBeNull())
  const callback = mocks.link!.onSuccess
  expect(JSON.parse(localStorage.getItem('household-cfo:plaid-oauth:v1')!)).toMatchObject({ householdId: 12, financialGeneration: 1 })
  if (reason === 'reset') { mocks.epoch += 1; mocks.financialGeneration += 1 } else view.unmount()
  await act(async () => callback('public-old-token', {}))
  expect(api.exchangePlaidPublicToken).not.toHaveBeenCalled(); expect(api.syncPlaidItem).not.toHaveBeenCalled()
})
test('old OAuth metadata is rejected after restart instead of silently rebinding the return', async () => {
  savePlaidOAuthSession({ userId: '42', householdId: 12, financialGeneration: 0, linkToken: 'link-sandbox-old', updateItemId: null })
  window.history.replaceState({}, '', '/?oauth_state_id=old')
  render(<PlaidConnections userId="42" householdId={12} onDraftsCreated={vi.fn()} />)
  await screen.findByRole('alert')
  expect(mocks.open).not.toHaveBeenCalled(); expect(api.exchangePlaidPublicToken).not.toHaveBeenCalled()
  expect(localStorage.getItem('household-cfo:plaid-oauth:v1')).toBeNull()
})

test('a delayed repair token cannot reopen a retained bank in a new picture', async () => {
  vi.mocked(api.fetchPlaidOverview).mockResolvedValue({ ...overview, items: [{ ...item, context_paused_by_restart: false, financial_generation: 1, status: 'update_required' }] })
  let resolve!: (value: { link_token: string }) => void
  vi.mocked(api.createPlaidUpdateLinkToken).mockImplementation(() => new Promise(done => { resolve = done }))
  render(<PlaidConnections userId="42" householdId={12} onDraftsCreated={vi.fn()} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Reconnect' }))
  mocks.epoch += 1; mocks.financialGeneration += 1
  await act(async () => resolve({ link_token: 'link-sandbox-old-repair' }))
  expect(mocks.open).not.toHaveBeenCalled(); expect(api.syncPlaidItem).not.toHaveBeenCalled()
  expect(localStorage.getItem('household-cfo:plaid-oauth:v1')).toBeNull()
})
test('an exchange reply crossing a restart cannot refresh or sync using a new context', async () => {
  vi.mocked(api.createPlaidLinkToken).mockResolvedValue({ link_token: 'link-sandbox-qa', consent_policy_version: '1' })
  let resolve!: (value: api.PlaidExchangeResult) => void
  vi.mocked(api.exchangePlaidPublicToken).mockImplementation(() => new Promise(done => { resolve = done }))
  render(<PlaidConnections userId="42" householdId={12} onDraftsCreated={vi.fn()} />)
  await connect(); await waitFor(() => expect(mocks.link).not.toBeNull())
  let pending!: Promise<void>
  act(() => { pending = mocks.link!.onSuccess('public-old-token', {}) })
  await waitFor(() => expect(api.exchangePlaidPublicToken).toHaveBeenCalledOnce())
  const reads = vi.mocked(api.fetchPlaidOverview).mock.calls.length
  mocks.epoch += 1; mocks.financialGeneration += 1
  await act(async () => { resolve({ item, plaid: overview }); await pending })
  expect(api.fetchPlaidOverview).toHaveBeenCalledTimes(reads)
  expect(api.syncPlaidItem).not.toHaveBeenCalled()
})
test('resumed connection keeps the previous balance hidden until a fresh sync timestamp arrives', async () => {
  const account: api.PlaidAccount = { id: 4, name: 'QA Checking', official_name: null, mask: null, type: 'depository', subtype: 'checking', current_balance_cents: 900000, available_balance_cents: null, currency: 'USD', active: true, eligible_for_asset_tracking: false, allowed_account_types: [], suggested_account_type: null, canonical_account_id: null, canonical_balance_known: false, canonical_balance_cents: null, observation_newer_than_saved: false }
  vi.mocked(api.fetchPlaidOverview).mockResolvedValue({ ...overview, items: [{ ...item, financial_generation: 1, context_paused_by_restart: false, financial_resumed_at: '2026-10-06T00:00:00Z', accounts: [account] }] })
  render(<PlaidConnections userId="42" householdId={12} onDraftsCreated={vi.fn()} />)
  await screen.findByText('Awaiting fresh balance')
  expect(screen.queryByText('$9,000.00')).toBeNull()
})
test('a failed resume displays its retryable error inside the still-open review', async () => {
  vi.mocked(api.resumePlaidItemFinancialPicture).mockRejectedValue(new Error('Connection changed. Refresh and review again.'))
  render(<PlaidConnections userId="42" householdId={12} onDraftsCreated={vi.fn()} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Use new bank activity' }))
  fireEvent.click(screen.getByLabelText('I want new activity from this bank included in my new financial picture.'))
  fireEvent.click(screen.getByRole('dialog').querySelector<HTMLButtonElement>('.primary-button')!)
  await waitFor(() => expect(screen.getByRole('dialog').querySelector('[role="alert"]')?.textContent).toBe('Connection changed. Refresh and review again.'))
  expect(screen.getByRole('dialog').querySelector<HTMLButtonElement>('.primary-button')!.disabled).toBe(false)
  expect(api.syncPlaidItem).not.toHaveBeenCalled()
})
