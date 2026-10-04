import { afterEach, describe, expect, it, vi } from 'vitest'
import { fetchSourceDuplicateCandidates, fetchStatementReviewRequestStatus, mutateStatementReview, setAuthTokenGetter } from '../api'
afterEach(() => { vi.unstubAllGlobals(); setAuthTokenGetter(null) })
describe('authenticated statement review adapters', () => {
  it('queries corrected duplicate facts and the explicit link filter through the app API', async () => {
    const fetch = vi.fn().mockImplementation(async () => new Response(JSON.stringify({ records: [], next_cursor: null }), { headers: { 'Content-Type': 'application/json' } })); vi.stubGlobal('fetch',fetch); setAuthTokenGetter(async () => 'fictional-token')
    await fetchSourceDuplicateCandidates(1203,4003,50,undefined,{ signed_amount_cents: -2_159, posted_on: '2026-09-15' })
    const url = new URL(fetch.mock.calls[0][0]); expect(url.pathname).toBe('/api/v1/document_imports/1203/review_candidates'); expect(Object.fromEntries(url.searchParams)).toEqual({ event_id: '4003', cursor: '50', filter: 'duplicate', signed_amount_cents: '-2159', posted_on: '2026-09-15' })
    expect(new Headers(fetch.mock.calls[0][1].headers).get('Authorization')).toBe('Bearer fictional-token')
    await fetchSourceDuplicateCandidates(1203,4003,null,undefined,{ filter: 'link' }); expect(new URL(fetch.mock.calls[1][0]).searchParams.get('filter')).toBe('link')
  })
  it('uses the original key in a private status header without putting it in a public URL', async () => {
    const fetch = vi.fn().mockResolvedValue(new Response(JSON.stringify({ state: 'in_flight' }), { status: 202, headers: { 'Content-Type': 'application/json' } })); vi.stubGlobal('fetch',fetch); setAuthTokenGetter(async () => 'fictional-token')
    expect(await fetchStatementReviewRequestStatus(1203,'approve','fictional-operation-key')).toEqual({ state: 'in_flight' })
    const url = new URL(fetch.mock.calls[0][0]); expect(url.pathname).toBe('/api/v1/document_imports/1203/review_request_status'); expect(url.search).toBe('?review_action=approve'); expect(url.href).not.toContain('fictional-operation-key')
    const headers = new Headers(fetch.mock.calls[0][1].headers); expect(headers.get('Idempotency-Key')).toBe('fictional-operation-key'); expect(headers.get('Authorization')).toBe('Bearer fictional-token')
  })
  it('sends exact economic links and project fingerprints in idempotent mutation requests', async () => {
    const fetch = vi.fn().mockResolvedValue(new Response(JSON.stringify({ record: { id: 701 }, replayed: false }), { headers: { 'Content-Type': 'application/json' } })); vi.stubGlobal('fetch',fetch)
    const input = { version_id: 401, expected_version_digest: 'approved-exact', projection: { action: 'create' }, reason: 'Compared funding sources.' }
    await mutateStatementReview(1203,88,'project',input,'frozen-request-key')
    expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({ revision_id: 88, input }); expect(new Headers(fetch.mock.calls[0][1].headers).get('Idempotency-Key')).toBe('frozen-request-key')
  })
})
