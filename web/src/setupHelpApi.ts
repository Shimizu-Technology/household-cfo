import { fetchPrivateJson, type FinancialRestartState } from './api'
import type { SetupHelpState, SetupSupportReason, SetupSupportRequest } from './lib/setupHelp'

export async function fetchSetupHelp(signal?: AbortSignal): Promise<SetupHelpState> {
  const result = await fetchPrivateJson<{ setup_help: SetupHelpState }>('/api/v1/setup_help', { signal, cache: 'no-store' })
  return result.setup_help
}
export function createSetupSupportRequest(reason: SetupSupportReason, requestKey: string) {
  return fetchPrivateJson<{ request: SetupSupportRequest; setup_help: SetupHelpState }>('/api/v1/setup_help/requests', {
    method: 'POST', cache: 'no-store', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': requestKey },
    body: JSON.stringify({ reason, share_metadata: true }),
  })
}
export function changeOwnSetupSupportRequest(id: number, action: 'cancel' | 'reopen', lockVersion: number) {
  return fetchPrivateJson<{ request: SetupSupportRequest; setup_help: SetupHelpState }>(`/api/v1/setup_help/requests/${id}/${action}`, {
    method: 'POST', cache: 'no-store', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ expected_lock_version: lockVersion }),
  })
}
export function fetchSetupSupportRequests(cohortId?: number | null, cursor?: number | null, signal?: AbortSignal) {
  const query = new URLSearchParams({ limit: '30' })
  if (cohortId != null) query.set('cohort_id', String(cohortId))
  if (cursor != null) query.set('cursor', String(cursor))
  return fetchPrivateJson<{ records: SetupSupportRequest[]; next_cursor: number | null }>(`/api/v1/setup_support_requests?${query}`, { signal, cache: 'no-store' })
}
export function updateSetupSupportRequest(id: number, action: 'triage' | 'prepare' | 'decline', lockVersion: number) {
  return fetchPrivateJson<{ request: SetupSupportRequest }>(`/api/v1/setup_support_requests/${id}/${action}`, {
    method: 'POST', cache: 'no-store', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ expected_lock_version: lockVersion }),
  })
}
export async function fetchSetupRestartStatus(reviewId?: number, requestId?: number): Promise<FinancialRestartState> {
  const query = new URLSearchParams()
  if (reviewId != null) query.set('review_id', String(reviewId))
  if (requestId != null) query.set('request_id', String(requestId))
  const state = (await fetchPrivateJson<{ financial_restart: FinancialRestartState }>(`/api/v1/setup_help/restart/status${query.size ? `?${query}` : ''}`, { cache: 'no-store' })).financial_restart
  return reviewId == null ? state : { ...state, review: state.review ?? state.latest_review }
}
async function restartAction(action: 'preview' | 'apply' | 'cancel', values: Record<string, unknown>, requestId?: number) {
  const result = await fetchPrivateJson<{ financial_restart: FinancialRestartState }>(`/api/v1/setup_help/restart/${action}`, {
    method: 'POST', cache: 'no-store', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...values, ...(requestId == null ? {} : { request_id: requestId }) }),
  })
  return result.financial_restart
}
export const previewSetupRestart = (requestId?: number) => restartAction('preview', {}, requestId)
export const applySetupRestart = (reviewId: number, acknowledged: boolean, requestId?: number) => restartAction('apply', { review_id: reviewId, confirmation: 'START OVER', shared_household_acknowledged: acknowledged }, requestId)
export const cancelSetupRestart = (reviewId: number, requestId?: number) => restartAction('cancel', { review_id: reviewId }, requestId)
