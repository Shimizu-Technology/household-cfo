// @vitest-environment jsdom
import { act, cleanup, renderHook, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { ApiRequestError, eraseDailyReflection, fetchDailyEraseStatus, fetchDailyRequestStatus, mutateDaily } from '../api'
import { setDailyExpectedUser } from './dailyRecovery'
import { useDailyMutation } from './useDailyMutation'
vi.mock('../api', async original => ({ ...await original<typeof import('../api')>(), eraseDailyReflection: vi.fn(), fetchDailyEraseStatus: vi.fn(), fetchDailyRequestStatus: vi.fn(), mutateDaily: vi.fn() }))
const scope = { user_id: 901, household_id: 77, enrollment_id: 100 }
const input = { erase_accepted: true, expected_version_id: 601, expected_head_lock_version: 3 }
afterEach(cleanup)
beforeEach(() => { vi.clearAllMocks(); sessionStorage.clear(); setDailyExpectedUser(null); setDailyExpectedUser(901) })
it('reconciles an uncertain erasure with tombstone-only status and no ordinary financial read', async () => {
  vi.mocked(eraseDailyReflection).mockRejectedValueOnce(new ApiRequestError('Interrupted.', { status: 503 }))
  vi.mocked(fetchDailyEraseStatus).mockResolvedValue({ state: 'committed', erased: true, reflection_id: 600, version_id: 601, replayed: true })
  const refresh = vi.fn(); const hook = renderHook(() => useDailyMutation(scope, refresh))
  await act(async () => { await hook.result.current.mutate('reflection_erase', input, 600) })
  const key = vi.mocked(eraseDailyReflection).mock.calls[0][2]
  expect(hook.result.current.busy).toBe(true)
  await act(async () => { await hook.result.current.checkStatus?.() })
  expect(fetchDailyEraseStatus).toHaveBeenCalledWith(600, key)
  expect(fetchDailyRequestStatus).not.toHaveBeenCalled()
  expect(refresh).toHaveBeenCalledOnce()
  expect(hook.result.current.busy).toBe(false)
})
it('retains the exact erasure key and body when status is unknown or names a different reflection', async () => {
  vi.mocked(eraseDailyReflection).mockRejectedValueOnce(new ApiRequestError('Interrupted.', { status: 503 })).mockResolvedValueOnce({ erased: true, reflection_id: 600, version_id: 601, replayed: true })
  vi.mocked(fetchDailyEraseStatus).mockResolvedValue({ state: 'committed', erased: true, reflection_id: 999, version_id: 601, replayed: true })
  const hook = renderHook(() => useDailyMutation(scope, vi.fn()))
  await act(async () => { await hook.result.current.mutate('reflection_erase', input, 600) })
  const first = vi.mocked(eraseDailyReflection).mock.calls[0]
  await act(async () => { await hook.result.current.checkStatus?.() })
  expect(hook.result.current.busy).toBe(true)
  expect(hook.result.current.error).toContain('could not be confirmed')
  await act(async () => { await hook.result.current.retry?.() })
  expect(vi.mocked(eraseDailyReflection).mock.calls[1]).toEqual(first)
  expect(hook.result.current.busy).toBe(false)
})
it('does not carry private erasure inputs into another enrollment or restore them from storage', async () => {
  vi.mocked(eraseDailyReflection).mockRejectedValue(new ApiRequestError('Interrupted.', { status: 503 }))
  vi.mocked(fetchDailyEraseStatus).mockResolvedValue({ state: 'unknown', can_retry: true })
  const hook = renderHook(({ current }) => useDailyMutation(current, vi.fn()), { initialProps: { current: scope } })
  await act(async () => { await hook.result.current.mutate('reflection_erase', input, 600) })
  expect(sessionStorage.getItem('daily-request-identities-v1')).not.toContain('erase_accepted')
  hook.rerender({ current: { ...scope, enrollment_id: 101 } })
  await waitFor(() => expect(hook.result.current.pending).toBeNull())
  hook.rerender({ current: scope })
  await waitFor(() => expect(hook.result.current.pending?.key).toBeTruthy())
  expect(hook.result.current.retry).toBeNull()
  await act(async () => { await hook.result.current.checkStatus?.() })
  expect(hook.result.current.error).toContain('no longer holds its original inputs')
  expect(hook.result.current.busy).toBe(true)
})

const selectedScope={...scope,cohort_id:55}
it.each([{enrollment_id:101,cohort_id:55},{enrollment_id:100,cohort_id:56},{}])('retains uncertain mutation and blocks a mismatched program result %j',async identity=>{
 vi.mocked(mutateDaily).mockResolvedValue({actor_scope:scope,...identity,record:{id:1},replayed:false})
 const refresh=vi.fn();const hook=renderHook(()=>useDailyMutation(selectedScope,refresh))
 await act(async()=>{expect(await hook.result.current.mutate('check_in_save',{})).toBeNull()})
 expect(hook.result.current.busy).toBe(true);expect(hook.result.current.denied).toBe(true);expect(refresh).not.toHaveBeenCalled()
})
it('does not clear recovery for a committed status from another enrollment',async()=>{
 vi.mocked(mutateDaily).mockRejectedValue(new ApiRequestError('Interrupted.',{status:503}))
 vi.mocked(fetchDailyRequestStatus).mockResolvedValue({actor_scope:scope,enrollment_id:101,cohort_id:55,state:'committed',record:{id:1},replayed:true})
 const refresh=vi.fn();const hook=renderHook(()=>useDailyMutation(selectedScope,refresh))
 await act(async()=>{await hook.result.current.mutate('check_in_save',{})})
 await act(async()=>{await hook.result.current.checkStatus?.()})
 expect(hook.result.current.busy).toBe(true);expect(hook.result.current.denied).toBe(true);expect(refresh).not.toHaveBeenCalled()
})
it.each([null,55])('keeps nil-enrollment in-flight status unresolved with cohort %s',async cohortId=>{
 vi.mocked(mutateDaily).mockRejectedValue(new ApiRequestError('Interrupted.',{status:503}))
 vi.mocked(fetchDailyRequestStatus).mockResolvedValue({actor_scope:scope,enrollment_id:null,cohort_id:cohortId,state:'in_flight'})
 const refresh=vi.fn();const hook=renderHook(()=>useDailyMutation(selectedScope,refresh))
 await act(async()=>{await hook.result.current.mutate('check_in_save',{})})
 const key=hook.result.current.pending!.key
 await act(async()=>{await hook.result.current.checkStatus?.()})
 expect(hook.result.current.pending?.key).toBe(key);expect(hook.result.current.busy).toBe(true);expect(hook.result.current.denied).toBe(false);expect(refresh).not.toHaveBeenCalled();expect(hook.result.current.error).toContain('still processing')
})
it('accepts exact selected-program results and clears their recovery',async()=>{
 vi.mocked(mutateDaily).mockResolvedValue({actor_scope:scope,enrollment_id:100,cohort_id:55,record:{id:1},replayed:false})
 const refresh=vi.fn();const hook=renderHook(()=>useDailyMutation(selectedScope,refresh))
 await act(async()=>{expect(await hook.result.current.mutate('check_in_save',{})).toEqual({id:1})})
 expect(hook.result.current.busy).toBe(false);expect(refresh).toHaveBeenCalledOnce()
})
