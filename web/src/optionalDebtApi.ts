import { fetchPrivateJson } from './api'
import type { DebtScope, OptionalDebtApi } from './lib/optionalDebt'
const base = '/api/v1/savings_challenge/debt'
const headers = (scope: number | DebtScope, key?: string) => ({ 'X-Cohort-Id': String(typeof scope === 'number' ? scope : scope.cohort_id), ...(key ? { 'Idempotency-Key': key } : {}) })
export const optionalDebtApi: OptionalDebtApi = {
  summary: (cohort, signal) => fetchPrivateJson(base, { signal, cache: 'no-store', headers: headers(cohort) }),
  records: (scope, kind, cursor, signal) => fetchPrivateJson(`${base}/records?kind=${kind}${cursor == null ? '' : `&cursor=${cursor}`}`, { signal, cache: 'no-store', headers: headers(scope) }),
  candidates: (scope, cursor, signal) => fetchPrivateJson(`${base}/source_candidates${cursor == null ? '' : `?cursor=${cursor}`}`, { signal, cache: 'no-store', headers: headers(scope) }),
  householdCandidates: (scope, cursor, signal) => fetchPrivateJson(`${base}/household_candidates${cursor == null ? '' : `?cursor=${cursor}`}`, { signal, cache: 'no-store', headers: headers(scope) }),
  mutate: (scope, action, input, key, signal) => fetchPrivateJson(`${base}/actions/${action}`, { method: 'POST', signal, cache: 'no-store', headers: { ...headers(scope, key), 'Content-Type': 'application/json' }, body: JSON.stringify(input) }),
  status: (scope, action, key, signal) => fetchPrivateJson(`${base}/request_status?review_action=${action}`, { signal, cache: 'no-store', headers: headers(scope, key) }),
}
