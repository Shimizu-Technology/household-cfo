import { fetchPrivateJson } from './api'
import type {
  EvidenceAction,
  EvidenceCandidates,
  EvidenceInput,
  EvidenceMutation,
  EvidencePage,
  EvidenceStatus,
} from './lib/savingsEvidence'
const base = '/api/v1/savings_challenge/evidence'
function query(entry: number, cursor?: number | null) {
  if (!Number.isSafeInteger(entry) || entry < 1 || (cursor != null && (!Number.isSafeInteger(cursor) || cursor < 1)))
    throw new Error('Reopen evidence from a valid savings entry.')
  return `entry_version_id=${entry}${cursor == null ? '' : `&cursor=${cursor}`}`
}
export function fetchSavingsEvidence(entry: number, cursor: number | null = null, signal?: AbortSignal) {
  return fetchPrivateJson<EvidencePage>(`${base}?${query(entry, cursor)}`, { signal, cache: 'no-store' })
}
export function fetchSavingsEvidenceCandidates(entry: number, cursor: number | null = null, signal?: AbortSignal) {
  return fetchPrivateJson<EvidenceCandidates>(`${base}/candidates?${query(entry, cursor)}`, {
    signal,
    cache: 'no-store',
  })
}
export function mutateSavingsEvidence(action: EvidenceAction, input: EvidenceInput, key: string, signal?: AbortSignal) {
  return fetchPrivateJson<EvidenceMutation>(`${base}/actions/${action}`, {
    method: 'POST',
    signal,
    cache: 'no-store',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': key },
    body: JSON.stringify(input),
  })
}
export function fetchSavingsEvidenceStatus(action: EvidenceAction, entry: number, key: string, signal?: AbortSignal) {
  return fetchPrivateJson<EvidenceStatus>(`${base}/request_status?review_action=${action}&${query(entry)}`, {
    signal,
    cache: 'no-store',
    headers: { 'Idempotency-Key': key },
  })
}
