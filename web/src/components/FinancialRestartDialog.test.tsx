// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { setApiFinancialGeneration, setAuthTokenGetter } from '../api'
import { FinancialRestartDialog } from './FinancialRestartDialog'

const review = { id: 13, status: 'pending', financial_generation: 0, expires_at: '2030-01-01T12:00:00Z', shared_member_count: 1,
  counts: { income_sources: 30, income_schedule_entries: 18, transactions: 20 }, reset_fields: [], preserved: ['Login and household members', 'BOG enrollment and approved savings'], paused: ['Earlier file applications'], clears_chat: false, clears_memories: false }
const state = { available: true, owner_required: false, financial_generation: 0, household_id: 1, household_name: 'Practice household', latest_review: null }
function json(value: unknown, status = 200) { return new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } }) }
let calls: Array<{ path: string; body: unknown }>
beforeEach(() => { calls = []; window.sessionStorage.clear(); setApiFinancialGeneration(null); setAuthTokenGetter(null) })
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.unstubAllGlobals(); setApiFinancialGeneration(null) })
function fake(extra: (path: string, body: unknown) => Response | Promise<Response> | undefined = () => undefined) {
  vi.stubGlobal('fetch', vi.fn(async (url: string, options: RequestInit) => {
    const path = String(url).replace(/^.*\/api/, '/api'); const body = options?.body ? JSON.parse(String(options.body)) : null
    calls.push({ path, body })
    const result = extra(path, body); if (result) return result
    if (path.endsWith('/preview')) return json({ financial_restart: { ...state, review } })
    if (path.endsWith('/cancel')) return json({ financial_restart: { ...state, review: { ...review, status: 'canceled' } } })
    return json({ financial_restart: state })
  }))
}
const scopeKey = 'user-901:901:participant:1:2'
const storageKey = `household-cfo:financial-restart:${scopeKey}`
async function open(onApplied = vi.fn(), onClose = vi.fn()) {
  const result = render(<FinancialRestartDialog scopeKey={scopeKey} onApplied={onApplied} onClose={onClose} />)
  await screen.findByText('Practice household')
  return { ...result, onApplied, onClose }
}
function confirm() { fireEvent.click(screen.getByLabelText(/I reviewed what starts fresh/)); fireEvent.click(screen.getByLabelText(/this changes the shared financial picture/)) }

it('shows exact scope and more than twelve records, and requires both explicit acknowledgments', async () => {
  fake(path => path.endsWith('/apply') ? json({ financial_restart: { ...state, financial_generation: 1, review: { ...review, status: 'applied', result_generation: 1 } } }) : undefined)
  const { onApplied } = await open()
  expect(screen.getByText('30')).toBeTruthy(); expect(screen.getByText('18')).toBeTruthy()
  const apply = screen.getByRole('button', { name: 'Start over with my real numbers' })
  expect((apply as HTMLButtonElement).disabled).toBe(true)
  fireEvent.click(screen.getByLabelText(/I reviewed what starts fresh/))
  expect((apply as HTMLButtonElement).disabled).toBe(true)
  fireEvent.click(screen.getByLabelText(/this changes the shared financial picture/))
  fireEvent.click(apply)
  await waitFor(() => expect(onApplied).toHaveBeenCalledWith(1))
  expect(calls.find(call => call.path.endsWith('/apply'))?.body).toEqual({ review_id: 13, confirmation: 'START OVER', shared_household_acknowledged: true })
  expect(window.sessionStorage.getItem(storageKey)).toBeNull()
})

it('cancels the reviewed request without applying any financial changes', async () => {
  fake(); const { onClose } = await open()
  fireEvent.click(screen.getByRole('button', { name: 'Keep my current picture' }))
  await waitFor(() => expect(onClose).toHaveBeenCalledOnce())
  expect(calls.find(call => call.path.endsWith('/cancel'))?.body).toEqual({ review_id: 13 })
  expect(calls.some(call => call.path.endsWith('/apply'))).toBe(false)
})

it('recovers the original pending request after a lost reply, then checks its exact committed receipt', async () => {
  let recoveries = 0
  fake(path => {
    if (path.endsWith('/apply')) return Promise.reject(new Error('Reply unavailable'))
    if (path.endsWith('/status?review_id=13')) return json({ financial_restart: { ...state, financial_generation: recoveries++ ? 1 : 0, latest_review: { ...review, status: recoveries > 1 ? 'applied' : 'pending', result_generation: recoveries > 1 ? 1 : null } } })
    return undefined
  })
  const first = await open(); confirm(); fireEvent.click(screen.getByRole('button', { name: 'Start over with my real numbers' }))
  await screen.findByRole('alert')
  await screen.findByRole('button', { name: 'Check whether start over finished' })
  expect(window.sessionStorage.getItem(storageKey)).toBe('13')
  fireEvent.click(screen.getByRole('button', { name: 'Close and check later' }))
  await waitFor(() => expect(first.onClose).toHaveBeenCalledOnce()); first.unmount()
  const second = await open()
  fireEvent.click(screen.getByRole('button', { name: 'Check whether start over finished' }))
  await waitFor(() => expect(second.onApplied).toHaveBeenCalledWith(1))
  expect(calls.filter(call => call.path.endsWith('/preview'))).toHaveLength(1)
  expect(calls.filter(call => call.path.endsWith('/apply'))).toHaveLength(1)
})

it('requires a fresh review after concurrent changes and clears the old acknowledgment', async () => {
  fake(path => path.endsWith('/apply') ? json({ code: 'financial_restart_review_stale', errors: ['The financial picture changed.'] }, 409) : undefined)
  await open(); confirm(); fireEvent.click(screen.getByRole('button', { name: 'Start over with my real numbers' }))
  await screen.findByText('The financial picture changed.')
  fireEvent.click(screen.getByRole('button', { name: 'Prepare a fresh review' }))
  await waitFor(() => expect(calls.filter(call => call.path.endsWith('/preview'))).toHaveLength(2))
  expect((screen.getByRole('button', { name: 'Start over with my real numbers' }) as HTMLButtonElement).disabled).toBe(true)
  expect(calls.filter(call => call.path.endsWith('/apply'))).toHaveLength(1)
})

it('does not request another household member’s inventory when owner access is unavailable', async () => {
  fake(path => path.endsWith('/status') ? json({ financial_restart: { ...state, available: false, owner_required: true } }) : undefined)
  render(<FinancialRestartDialog scopeKey="partner-scope" onClose={vi.fn()} onApplied={vi.fn()} />)
  await screen.findByText(/Only the household owner/)
  expect(calls.filter(call => call.path.endsWith('/preview') || call.path.endsWith('/apply'))).toHaveLength(0)
  expect(screen.queryByText('30')).toBeNull()
})

it('fails before applying if safe request recovery cannot be retained', async () => {
  fake(); await open(); confirm()
  vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('Blocked') })
  fireEvent.click(screen.getByRole('button', { name: 'Start over with my real numbers' }))
  await screen.findByText(/cannot keep the request reference/)
  expect(calls.some(call => call.path.endsWith('/apply'))).toBe(false)
})
