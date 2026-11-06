// @vitest-environment jsdom
import { act, cleanup, renderHook, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { fetchChallengeChatCards } from '../api'
import { clearDailyCards, readDailyCard, registerDailyCard, restoreDailyCards, useDailyCard } from './dailyCheckIn'
import { useChallengeChatCards } from './useChallengeChatCards'
import type { ChallengeChatCard, ChallengeChatCards } from './challengeChatCards'
vi.mock('../api', async original => ({ ...await original<typeof import('../api')>(), fetchChallengeChatCards: vi.fn() }))
const scope = 'participant:1:2:3'
const actor = { user_id: 1, household_id: 2 }
const card: ChallengeChatCard = { id: 30, kind: 'daily_report', message_id: 20, enrollment_id: 10, status: 'pending', lock_version: 0,
  input: { kind: 'daily_report', local_on: '2026-11-02', no_spend: false, purchases: [{ amount_cents: 1475, merchant: 'Kmart', purchased_on: '2026-11-02' }], feelings: { when_spent: 'rushed', now: 'guilty' }, approval_state: 'unreviewed_input', counted: false }, state: {} }
const response = (records: ChallengeChatCard[]): ChallengeChatCards => ({ records, actor_scope: actor, cohort_id: 3, enrollment_id: 10 })
beforeEach(() => { clearDailyCards(); sessionStorage.clear(); vi.resetAllMocks() })
afterEach(() => { cleanup(); clearDailyCards() })
it('removes private session cards absent from the authoritative server result', async () => {
  if (!('kind' in card.input) || card.input.kind !== 'daily_report') throw new Error('fixture')
  registerDailyCard({ scope, nonce: 'server-card-30', report: card.input })
  renderHook(() => useDailyCard('server-card-30', () => ({ rows: [], phase: 'idle', feelingThen: 'private', feelingNow: '', keys: {}, message: null, switchedToSpending: [], checkedIn: [], noSpendSaved: false })))
  expect(readDailyCard('server-card-30')).toBeDefined()
  vi.mocked(fetchChallengeChatCards).mockResolvedValue(response([]))
  const hook = renderHook(() => useChallengeChatCards(true, scope, actor, 3))
  await waitFor(() => expect(readDailyCard('server-card-30')).toBeUndefined())
  expect(hook.result.current.reports).toEqual([])
  expect(restoreDailyCards(scope)).toEqual([])
})
it('clear removes private inputs and ignores an older restoration response', async () => {
  let resolve!: (value: ChallengeChatCards) => void
  vi.mocked(fetchChallengeChatCards).mockReturnValue(new Promise(done => { resolve = done }))
  const hook = renderHook(() => useChallengeChatCards(true, scope, actor, 3))
  act(() => hook.result.current.accept(card))
  expect(hook.result.current.reports).toHaveLength(1)
  act(() => hook.result.current.clear())
  await act(async () => resolve(response([card])))
  expect(hook.result.current.reports).toEqual([])
  expect(readDailyCard('server-card-30')).toBeUndefined()
  expect(restoreDailyCards(scope)).toEqual([])
})
it('keeps a newly received card while an older restoration response arrives', async () => {
  let resolve!: (value: ChallengeChatCards) => void
  vi.mocked(fetchChallengeChatCards).mockReturnValue(new Promise(done => { resolve = done }))
  const hook = renderHook(() => useChallengeChatCards(true, scope, actor, 3))
  act(() => hook.result.current.accept(card))
  await act(async () => resolve(response([])))
  expect(hook.result.current.reports).toHaveLength(1)
})

it('accepts a just-created server card while the enrollment read is still loading', () => {
  const hook = renderHook(() => useChallengeChatCards(false, scope, actor, 3))
  act(() => hook.result.current.accept(card))
  expect(hook.result.current.reports).toHaveLength(1)
})

it('offers recovery when server restoration fails instead of silently losing the card', async () => {
  vi.mocked(fetchChallengeChatCards).mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce(response([card]))
  const hook = renderHook(() => useChallengeChatCards(true, scope, actor, 3))
  await waitFor(() => expect(hook.result.current.readFailed).toBe(true))
  act(() => hook.result.current.retry())
  await waitFor(() => expect(hook.result.current.reports).toHaveLength(1))
  expect(hook.result.current.readFailed).toBe(false)
})

it('restores set-aside and withdrawal review cards and removes closed cards on a later turn', async () => {
  const savings: ChallengeChatCard = { ...card, kind: 'savings', input: { kind: 'contribution', amount_cents: 2500, signed_cents: 2500, effective_on: '2026-11-02', counted: false, approval_state: 'unreviewed_input' } }
  vi.mocked(fetchChallengeChatCards).mockResolvedValueOnce(response([savings])).mockResolvedValueOnce(response([]))
  const hook = renderHook(() => useChallengeChatCards(true, scope, actor, 3))
  await waitFor(() => expect(hook.result.current.savings).toEqual([savings]))
  act(() => hook.result.current.retry())
  await waitFor(() => expect(hook.result.current.savings).toEqual([]))
  expect(hook.result.current.reports).toEqual([])
})

it('keeps both independently reviewed facts from one message through a delayed restore', async () => {
  let finish!: (result: ChallengeChatCards) => void
  vi.mocked(fetchChallengeChatCards).mockReturnValue(new Promise(resolve => { finish = resolve }))
  const hook = renderHook(() => useChallengeChatCards(true, scope, actor, 3))
  const savings: ChallengeChatCard = { ...card, id: 31, kind: 'savings', input: { kind: 'contribution', amount_cents: 700, signed_cents: 700, effective_on: '2026-11-02', counted: false, approval_state: 'unreviewed_input' } }
  act(() => { hook.result.current.accept(savings); hook.result.current.accept(card) })
  expect(hook.result.current.savings).toEqual([savings])
  expect(hook.result.current.reports.map(report => report.nonce)).toEqual(['server-card-30'])
  await act(async () => { finish(response([])) })
  expect(hook.result.current.savings).toEqual([savings])
  expect(hook.result.current.reports).toHaveLength(1)
})
