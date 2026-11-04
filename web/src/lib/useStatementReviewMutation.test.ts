// @vitest-environment jsdom
import { act, cleanup, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { ApiRequestError, fetchStatementReviewRequestStatus, mutateStatementReview } from '../api'
import { setStatementReviewExpectedUser } from './statementReviewRecovery'
import { useStatementReviewMutation } from './useStatementReviewMutation'

vi.mock('../api', async original => ({ ...await original<typeof import('../api')>(), fetchStatementReviewRequestStatus: vi.fn(), mutateStatementReview: vi.fn() }))
const scope = { user_id: 901, household_id: 77 }
beforeEach(() => { vi.clearAllMocks(); sessionStorage.clear(); setStatementReviewExpectedUser(null); setStatementReviewExpectedUser(901) })
afterEach(() => { cleanup(); vi.restoreAllMocks() })

it('keeps the saved request and review visible when checking its result is temporarily unavailable', async () => {
  vi.mocked(mutateStatementReview).mockRejectedValueOnce(new ApiRequestError('Interrupted', { status: 503 }))
  vi.mocked(fetchStatementReviewRequestStatus).mockRejectedValueOnce(new ApiRequestError('This part of your program is not available right now.', { status: 403, code: 'savings_challenge_unavailable' }))
  const hook = renderHook(() => useStatementReviewMutation({ scope, importId: 5, revisionId: 6, refresh: vi.fn() }))
  await act(async () => { await hook.result.current.mutate('approve_lines', { lines: [{ event_id: 7, decision: 'leave_out' }] }) })
  const key = hook.result.current.pendingRequest?.key
  expect(key).toBeTruthy()
  await act(async () => { await hook.result.current.checkStatus?.() })
  expect(hook.result.current.accessDenied).toBe(false)
  expect(hook.result.current.pendingRequest?.key).toBe(key)
  expect(hook.result.current.pendingRequest?.input).toEqual({ lines: [{ event_id: 7, decision: 'leave_out' }] })
  expect(hook.result.current.error).toContain('not available right now')
})

it('hides private review data for an ordinary access denial', async () => {
  vi.mocked(mutateStatementReview).mockRejectedValueOnce(new ApiRequestError('Access denied', { status: 403 }))
  const hook = renderHook(() => useStatementReviewMutation({ scope, importId: 5, revisionId: 6, refresh: vi.fn() }))
  await act(async () => { await hook.result.current.mutate('approve_lines', { lines: [{ event_id: 7, decision: 'leave_out' }] }) })
  expect(hook.result.current.accessDenied).toBe(true)
  expect(hook.result.current.pendingRequest).toBeNull()
})
