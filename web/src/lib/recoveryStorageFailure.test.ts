// @vitest-environment jsdom
import { act, cleanup, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { ApiRequestError, approveFinancialBaseline, eraseDailyReflection, mutateDaily, mutateStatementReview, stageSavingsPlan } from '../api'
import { setDailyExpectedUser } from './dailyRecovery'
import { setBaselineExpectedUser } from './baselineRecovery'
import { setStatementReviewExpectedUser } from './statementReviewRecovery'
import { bindPlanScope } from './comfortablePlanRecovery'
import { useDailyMutation } from './useDailyMutation'
import { useBaselineMutation } from './useBaselineMutation'
import { useStatementReviewMutation } from './useStatementReviewMutation'
import { useComfortablePlanMutation } from './useComfortablePlanMutation'
import type { BaselineApproval } from './financialBaseline'
vi.mock('../api', async original => ({ ...await original<typeof import('../api')>(), approveFinancialBaseline: vi.fn(), eraseDailyReflection: vi.fn(), mutateDaily: vi.fn(), mutateStatementReview: vi.fn(), stageSavingsPlan: vi.fn() }))
const actor = { user_id: 901, household_id: 77 }, scope = { ...actor, enrollment_id: 1, cohort_id: 42 }
const baseline: BaselineApproval = { request: { window_start_on: '2026-10-01', window_end_on: '2026-10-04', revision_ids: [], tracked_account_ids: [], household_scope_attested: false, missing_accounts: [], cash_coverage: 'unknown', category_eligibility: [], actual_decisions: [], cash_allocations: [] }, expected_preview_digest: 'a'.repeat(64), base_version_id: null, base_lock_version: 0, coverage_status: 'manual', reason: 'Fictional test' }
const plan = { target_cents: 25000, expected_plan_version_id: null, reason: 'Fictional test', financial_baseline_version_id: null, baseline_digest: null, spending_changes: [] }
beforeEach(() => { vi.clearAllMocks(); sessionStorage.clear(); setDailyExpectedUser(null); setDailyExpectedUser(901); setBaselineExpectedUser(null); setBaselineExpectedUser(901); setStatementReviewExpectedUser(null); setStatementReviewExpectedUser(901); bindPlanScope(null) })
afterEach(() => { cleanup(); vi.restoreAllMocks() })
const failures = ['quota', 'disabled', 'silently ignored'] as const
function block(mode: typeof failures[number]) {
  if (mode === 'disabled') return vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => { throw new DOMException('Storage disabled', 'SecurityError') })
  return vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { if (mode === 'quota') throw new DOMException('Quota exceeded', 'QuotaExceededError') })
}
it.each(failures)('daily writes and self-erasure are not dispatched when identity storage is %s', async mode => {
  const hook = renderHook(() => useDailyMutation(scope, vi.fn())); const storage = block(mode)
  await act(async () => { expect(await hook.result.current.mutate('check_in_save', {})).toBeNull() })
  expect(mutateDaily).not.toHaveBeenCalled(); expect(hook.result.current.error).toContain('No change was submitted'); expect(hook.result.current.pending).toBeNull()
  await act(async () => { expect(await hook.result.current.mutate('reflection_erase', { erase_accepted: true }, 7)).toBeNull() })
  expect(eraseDailyReflection).not.toHaveBeenCalled(); storage.mockRestore()
})
it.each(failures)('baseline approval/revision is not dispatched when identity storage is %s', async mode => {
  const hook = renderHook(() => useBaselineMutation({ scope: actor, refresh: vi.fn() })); const storage = block(mode)
  for (const action of ['approve', 'revise'] as const) await act(async () => { expect(await hook.result.current.mutate(action, baseline)).toBe(false) })
  expect(approveFinancialBaseline).not.toHaveBeenCalled(); expect(hook.result.current.error).toContain('No change was submitted'); expect(hook.result.current.pendingRequest).toBeNull(); storage.mockRestore()
})
it.each(failures)('statement approval is not dispatched when identity storage is %s', async mode => {
  const hook = renderHook(() => useStatementReviewMutation({ scope: actor, importId: 5, revisionId: 6, refresh: vi.fn() })); const storage = block(mode)
  await act(async () => { expect(await hook.result.current.mutate('approve', { accepted: true })).toBe(false) })
  expect(mutateStatementReview).not.toHaveBeenCalled(); expect(hook.result.current.error).toContain('No change was submitted'); expect(hook.result.current.pendingRequest).toBeNull(); storage.mockRestore()
})
it.each(failures)('comfortable plan is not dispatched when identity storage is %s', async mode => {
  const hook = renderHook(() => useComfortablePlanMutation(scope, vi.fn(), vi.fn())); await act(async () => {}); const storage = block(mode)
  await act(async () => { await hook.result.current.perform('plan_stage', plan) })
  expect(stageSavingsPlan).not.toHaveBeenCalled(); expect(hook.result.current.error).toContain('No change was submitted'); expect(hook.result.current.pending).toBeNull(); storage.mockRestore()
})
it('can submit after storage is restored and preserves an earlier key when a retry cannot persist', async () => {
  vi.mocked(mutateDaily).mockRejectedValueOnce(new ApiRequestError('Interrupted', { status: 503 })).mockResolvedValueOnce({ actor_scope: actor, enrollment_id: scope.enrollment_id, cohort_id: scope.cohort_id, record: { id: 2 }, replayed: true })
  const refresh = vi.fn(), hook = renderHook(() => useDailyMutation(scope, refresh))
  const firstBlock = block('quota')
  await act(async () => { await hook.result.current.mutate('check_in_save', { fictional: 'private contents' }) }); firstBlock.mockRestore()
  await act(async () => { await hook.result.current.mutate('check_in_save', { fictional: 'private contents' }) })
  expect(mutateDaily).toHaveBeenCalledOnce(); const original = vi.mocked(mutateDaily).mock.calls[0]; const stored = sessionStorage.getItem('daily-request-identities-v1')
  expect(stored).toContain(original[2]); expect(stored).not.toContain('private contents')
  const retryBlock = block('quota')
  await act(async () => { await hook.result.current.retry?.() }); retryBlock.mockRestore()
  expect(mutateDaily).toHaveBeenCalledOnce(); expect(hook.result.current.pending?.key).toBe(original[2]); expect(hook.result.current.error).toContain('No change was submitted'); expect(hook.result.current.pending?.working).toBe(false)
  await act(async () => { await hook.result.current.retry?.() })
  expect(vi.mocked(mutateDaily).mock.calls[1]).toEqual(original); expect(refresh).toHaveBeenCalledOnce(); expect(hook.result.current.pending).toBeNull()
})
