// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { dailyContext } from '../test/dailyFixtures'
import type { DailyReportIntake } from './savingsChallenge'

const report: DailyReportIntake = { kind: 'daily_report', local_on: '2026-10-21', purchases: [{ amount_cents: 800, merchant: 'Shell', purchased_on: '2026-10-21' }], no_spend: false, feelings: null, counted: false, approval_state: 'unreviewed_input' }
const init = () => ({ rows: [{ id: 0, amount: '8.00', merchant: 'Shell', purchased_on: '2026-10-21', status: 'pending' as const }], feelingThen: '', feelingNow: '', keys: {}, phase: 'idle' as const, message: null, switchedToSpending: [], checkedIn: [], noSpendSaved: false })
afterEach(() => { sessionStorage.clear(); vi.resetModules() })

describe('daily check-in helpers', () => {
  it('turns a save conflict from another window into a reopen-Ask-Mia message', async () => {
    const { registerServerDailyCard, syncDailyCard } = await import('./dailyCheckIn')
    const api = await import('../api')
    const update = vi.spyOn(api, 'updateChallengeChatCard')
    const server = { id: 71, kind: 'daily_report' as const, status: 'pending' as const, lock_version: 0, enrollment_id: 10, message_id: 21, input: report, state: init() }
    const entry = registerServerDailyCard(server, 'conflict-test')!
    update.mockRejectedValueOnce(new api.ApiRequestError('Conflict', { status: 409 }))
    await expect(syncDailyCard(entry.nonce)).rejects.toThrow('This check-in changed in another window. Reopen Ask Mia.')
    expect(update).toHaveBeenCalledWith(71, expect.objectContaining({ action: 'save_state', expected_lock_version: 0 }))
  })

  it('holds money prompts under a server-flagged safety reply until an ordinary reply follows', async () => {
    const { latestReplyIsSafety } = await import('./dailyCheckIn')
    expect(latestReplyIsSafety([{ role: 'user' }, { role: 'assistant', safety_reply: true }])).toBe(true)
    expect(latestReplyIsSafety([{ role: 'assistant', safety_reply: true }, { role: 'user' }])).toBe(true)
    expect(latestReplyIsSafety([{ role: 'assistant', safety_reply: true }, { role: 'user' }, { role: 'assistant', safety_reply: false }])).toBe(false)
    expect(latestReplyIsSafety([{ role: 'assistant', content: 'Call or text 988' } as { role: string }])).toBe(false)
  })

  it('counts a day as checked in only after a spending or no-spend report is saved', async () => {
    const { dayCheckedIn } = await import('./dailyCheckIn')
    const day = dailyContext.day!
    expect(dayCheckedIn({ ...day, approved_purchase_count: 1, spending_state: 'unknown', checked_in: undefined })).toBe(false)
    expect(dayCheckedIn({ ...day, spending_state: 'spending', checked_in: undefined })).toBe(true)
    expect(dayCheckedIn({ ...day, spending_state: 'no_spend', checked_in: undefined })).toBe(true)
    expect(dayCheckedIn({ ...day, approved_purchase_count: 2, checked_in: false })).toBe(false)
  })

  it('restores a card after a reload for the same scope only, with an in-flight row left to check', async () => {
    const first = await import('./dailyCheckIn')
    first.registerDailyCard({ scope: 'a:1:77:5', report, nonce: 'n1' })
    first.registerDailyCard({ scope: 'a:1:77:5', report, nonce: 'n2' })
    // Seed through the hook path's store writes.
    const { renderHook } = await import('@testing-library/react')
    renderHook(() => first.useDailyCard('n1', init))
    renderHook(() => first.useDailyCard('n2', init))
    first.writeDailyCard('n1', (state) => ({ ...state, phase: 'saving', rows: [{ ...state.rows[0], status: 'saving' }], unconfirmed: { action: 'purchase_approve', input: { draft_id: 300 }, key: 'k1', rowId: 0 } }))
    first.writeDailyCard('n2', (state) => ({ ...state, phase: 'saved', feelingThen: 'private feeling', keys: { stage: 'old-key' }, rows: [{ ...state.rows[0], status: 'saved' }] }))
    vi.resetModules()
    const reloaded = await import('./dailyCheckIn')
    expect(reloaded.restoreDailyCards('a:2:77:5')).toEqual([])
    const restored = reloaded.restoreDailyCards('a:1:77:5')
    expect(restored.map((entry) => entry.nonce)).toEqual(['n1', 'n2'])
    expect(reloaded.readDailyCard('n1')).toMatchObject({ phase: 'idle', rows: [{ status: 'unknown' }], unconfirmed: { key: 'k1' } })
    expect(reloaded.readDailyCard('n2')).toMatchObject({ phase: 'saved', feelingThen: '', keys: {} })
    reloaded.clearDailyCards('a:2:77:5')
    expect(reloaded.readDailyCard('n1')).toBeDefined()
    reloaded.forgetDailyCard('n2')
    expect(JSON.parse(sessionStorage.getItem('household-cfo:mia-daily-cards:v1:a:1:77:5')!).map((item: { nonce: string }) => item.nonce)).toEqual(['n1'])
    reloaded.clearDailyCards()
    expect(Object.keys(sessionStorage).filter((key) => key.includes('mia-daily-cards'))).toEqual([])
    expect(reloaded.readDailyCard('n1')).toBeUndefined()
  })
  it('uses newer server lock versions without overwriting local edits or request keys', async () => {
    const { registerServerDailyCard, writeDailyCard, readDailyCard, syncDailyCard, useDailyCard, clearDailyCards } = await import('./dailyCheckIn')
    const update = vi.spyOn(await import('../api'), 'updateChallengeChatCard')
    const server = { id: 70, kind: 'daily_report' as const, status: 'pending' as const, lock_version: 0, enrollment_id: 10, message_id: 20, input: report, state: {} }
    const entry = registerServerDailyCard(server, 'lock-test')!
    const { renderHook, act } = await import('@testing-library/react')
    const view = renderHook(() => useDailyCard(entry.nonce, init))
    act(() => writeDailyCard(entry.nonce, state => ({ ...state, feelingNow: 'local', keys: { local: 'key' } })))
    registerServerDailyCard({ ...server, lock_version: 4, state: { ...init(), feelingNow: 'other tab' } }, 'lock-test')
    registerServerDailyCard({ ...server, lock_version: 2 }, 'lock-test')
    update.mockResolvedValue({ record: { ...server, lock_version: 5 }, challenge: {} as never })
    await act(async () => { await syncDailyCard(entry.nonce) })
    expect(update).toHaveBeenCalledWith(70, expect.objectContaining({ expected_lock_version: 4, state: expect.objectContaining({ feelingNow: 'local', keys: { local: 'key' } }) }))
    expect(readDailyCard(entry.nonce)?.feelingNow).toBe('local')
    let finish!: (result: Awaited<ReturnType<typeof update>>) => void
    update.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
    await act(async () => {
      const saving = syncDailyCard(entry.nonce)
      await Promise.resolve()
      await Promise.resolve()
      expect(update).toHaveBeenLastCalledWith(70, expect.objectContaining({ expected_lock_version: 5 }))
      registerServerDailyCard({ ...server, lock_version: 8 }, 'lock-test')
      finish({ record: { ...server, lock_version: 6 }, challenge: {} as never })
      await saving
    })
    update.mockResolvedValue({ record: { ...server, lock_version: 9 }, challenge: {} as never })
    await act(async () => { await syncDailyCard(entry.nonce) })
    expect(update).toHaveBeenLastCalledWith(70, expect.objectContaining({ expected_lock_version: 8 }))
    view.unmount(); clearDailyCards(); update.mockRestore()
  })

})

it('closes stale today context while an explicit refresh is still loading', async () => {
  const api = await import('../api')
  const {useTodayCheckIn} = await import('./dailyCheckIn')
  const {renderHook,waitFor,cleanup} = await import('@testing-library/react')
  const scope={user_id:901,household_id:77}
  const current={...dailyContext,actor_scope:scope}
  const read=vi.spyOn(api,'fetchDailyContext').mockResolvedValueOnce(current)
  const hook=renderHook(({revision})=>useTodayCheckIn(scope,current.cohort_id ?? undefined,true,revision),{initialProps:{revision:0}})
  await waitFor(()=>expect(hook.result.current.context).not.toBeNull())
  read.mockReturnValueOnce(new Promise(()=>{}))
  hook.rerender({revision:1})
  expect(hook.result.current.context).toBeNull()
  cleanup()
})
