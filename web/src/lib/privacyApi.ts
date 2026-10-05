import { fetchPrivateJson } from '../api'
import type { PrivacyApi, RequestIdentity } from './challengePrivacy'

const base = '/api/v1/savings_challenge'
const query = (cursor?: number | null) => cursor == null ? '' : `?cursor=${cursor}`
function requestPath(identity: RequestIdentity, status = false) {
  if (identity.action === 'erase') return `${base}/daily/reflections/${identity.reflectionId}/${status ? 'erase_status' : 'erase'}`
  const reminders = identity.action === 'preference' || identity.action === 'dismiss'
  const root = `${base}/${identity.enrollmentId}/${reminders ? 'reminders' : 'privacy'}`
  return status ? `${root}/request_status?${reminders ? 'reminder_action' : 'privacy_action'}=${identity.action}` : `${root}/${identity.action}`
}
export const privacyApi: PrivacyApi = {
  controls: (cursor, signal) => fetchPrivateJson(`${base}/private_controls${query(cursor)}`, { signal, cache: 'no-store' }),
  privacy: (id, cursor, signal) => fetchPrivateJson(`${base}/${id}/privacy${cursor == null ? '' : `?reflections_cursor=${cursor}`}`, { signal, cache: 'no-store' }),
  candidates: (id, type, cursor, signal) => fetchPrivateJson(`${base}/${id}/privacy/selection_candidates?record_type=${type}${cursor == null ? '' : `&cursor=${cursor}`}`, { signal, cache: 'no-store' }),
  source: (id, sourceId, signal) => fetchPrivateJson(`${base}/${id}/source_use/${sourceId}`, { signal, cache: 'no-store' }),
  reminders: (id, signal) => fetchPrivateJson(`${base}/${id}/reminders`, { signal, cache: 'no-store' }),
  mutate: (identity, input, signal) => fetchPrivateJson(requestPath(identity), { method: 'POST', signal, cache: 'no-store', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': identity.key }, body: JSON.stringify(input) }),
  status: (identity, signal) => fetchPrivateJson(requestPath(identity, true), { signal, cache: 'no-store', headers: { 'Idempotency-Key': identity.key } }),
}
