// @vitest-environment jsdom
import { act, cleanup, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { updateChallengeChatCard } from '../api'
import { clearDailyCards, forgetDailyCard, dismissDailyCard, readDailyCard, registerServerDailyCard, syncDailyCard, useDailyCard, writeDailyCard } from './dailyCheckIn'
import type { ChallengeChatCard } from './challengeChatCards'
import type { DailyCardState } from './dailyCheckIn'
vi.mock('../api', async original => ({ ...await original<typeof import('../api')>(), updateChallengeChatCard: vi.fn() }))
const card: ChallengeChatCard = { id: 30, kind: 'daily_report', message_id: 20, enrollment_id: 10, status: 'pending', lock_version: 2,
  input: { kind: 'daily_report', local_on: '2026-11-02', no_spend: false, purchases: [{ amount_cents: 1475, merchant: 'Kmart', purchased_on: '2026-11-02' }], feelings: { when_spent: 'rushed', now: 'guilty' }, approval_state: 'unreviewed_input', counted: false }, state: {} }
const state: DailyCardState = { rows: [{ id: 0, amount: '14.75', merchant: 'Kmart', purchased_on: '2026-11-02', status: 'saving' }], phase: 'saving', keys: { stage: 'stable-key' }, feelingThen: 'rushed', feelingNow: 'guilty', message: null, switchedToSpending: [], checkedIn: [], noSpendSaved: false, unconfirmed: { action: 'purchase_stage', key: 'stable-key', input: { amount_cents: 1475 }, rowId: 0 } }
beforeEach(() => { clearDailyCards(); sessionStorage.clear(); vi.resetAllMocks() })
afterEach(() => { cleanup(); clearDailyCards() })
it('restores server progress with no tab storage and keeps an interrupted request locked for reconciliation', () => {
  const entry = registerServerDailyCard({ ...card, state }, 'participant:1:2:3')!
  expect(entry.nonce).toBe('server-card-30')
  expect(readDailyCard(entry.nonce)).toMatchObject({ phase: 'idle', rows: [{ status: 'unknown' }], unconfirmed: { key: 'stable-key' }, feelingThen: 'rushed' })
  expect(registerServerDailyCard({ ...card, status: 'closed' }, 'participant:1:2:3')).toBeNull()
})
it('serializes progress and dismissal with the latest server version', async () => {
  let version = card.lock_version
  vi.mocked(updateChallengeChatCard).mockImplementation(async (_id, input) => {
    expect(input.expected_lock_version).toBe(version)
    version += 1
    return { record: { ...card, lock_version: version, status: input.action === 'dismiss' ? 'closed' : 'pending' }, challenge: {} as never }
  })
  const entry = registerServerDailyCard(card, 'participant:1:2:3')!
  renderHook(() => useDailyCard(entry.nonce, () => ({ ...state, phase: 'idle' })))
  act(() => writeDailyCard(entry.nonce, current => ({ ...current, feelingNow: 'calmer' })))
  await syncDailyCard(entry.nonce)
  await dismissDailyCard(entry.nonce)
  const calls = vi.mocked(updateChallengeChatCard).mock.calls
  expect(calls.at(-1)?.[1]).toMatchObject({ action: 'dismiss' })
  expect(calls[0][1]).toMatchObject({ action: 'save_state', state: { feelingNow: 'calmer', keys: { stage: 'stable-key' } } })
  expect(readDailyCard(entry.nonce)).toBeUndefined()
})

it('refuses a closed server response before authorizing a stale tab financial write', async () => {
  const entry = registerServerDailyCard({ ...card, state: { ...state, phase: 'idle' } }, 'participant:1:2:3')!
  vi.mocked(updateChallengeChatCard).mockResolvedValue({ record: { ...card, status: 'closed' }, challenge: {} as never })
  await expect(syncDailyCard(entry.nonce)).rejects.toThrow(/another window/)
  await expect(syncDailyCard(entry.nonce)).rejects.toThrow(/another window/)
})
it('rejects an in-flight sync after the card is forgotten', async () => {
  const entry = registerServerDailyCard({ ...card, state }, 'participant:1:2:3')!
  let resolve!: (value: Awaited<ReturnType<typeof updateChallengeChatCard>>) => void
  vi.mocked(updateChallengeChatCard).mockReturnValue(new Promise(done => { resolve = done }))
  const syncing = syncDailyCard(entry.nonce)
  await vi.waitFor(() => expect(updateChallengeChatCard).toHaveBeenCalled())
  forgetDailyCard(entry.nonce)
  resolve({ record: { ...card, lock_version: 3 }, challenge: {} as never })
  await expect(syncing).rejects.toThrow(/cleared/)
})
