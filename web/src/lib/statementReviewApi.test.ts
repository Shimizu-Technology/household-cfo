import { afterEach, describe, expect, it, vi } from 'vitest'
import { fetchStatementReviewRequestStatus, mutateStatementReview, setAuthTokenGetter } from '../api'
afterEach(() => { vi.unstubAllGlobals(); setAuthTokenGetter(null) })
describe('authenticated statement review adapters', () => {
  it('uses the original key in a private status header without putting it in a public URL', async () => {
    const fetch = vi.fn().mockResolvedValue(new Response(JSON.stringify({ state: 'in_flight' }), { status: 202, headers: { 'Content-Type': 'application/json' } })); vi.stubGlobal('fetch',fetch); setAuthTokenGetter(async () => 'fictional-token')
    expect(await fetchStatementReviewRequestStatus(1203,'approve_lines','fictional-operation-key')).toEqual({ state: 'in_flight' })
    const url = new URL(fetch.mock.calls[0][0]); expect(url.pathname).toBe('/api/v1/document_imports/1203/review_request_status'); expect(url.search).toBe('?review_action=approve_lines'); expect(url.href).not.toContain('fictional-operation-key')
    const headers = new Headers(fetch.mock.calls[0][1].headers); expect(headers.get('Idempotency-Key')).toBe('fictional-operation-key'); expect(headers.get('Authorization')).toBe('Bearer fictional-token')
  })
  it('sends the exact lines being approved in one idempotent request', async () => {
    const fetch = vi.fn().mockResolvedValue(new Response(JSON.stringify({ result: { approved: 2 } }), { headers: { 'Content-Type': 'application/json' } })); vi.stubGlobal('fetch',fetch)
    const input = { expect_ready_ids: [4001, 4002], lines: [{ event_id: 4001, decision: 'as_read' }, { event_id: 4002, decision: 'as_read' }] }
    await mutateStatementReview(1203,88,'approve_lines',input,'frozen-request-key')
    expect(new URL(fetch.mock.calls[0][0]).pathname).toBe('/api/v1/document_imports/1203/review/approve_lines')
    expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({ revision_id: 88, input }); expect(new Headers(fetch.mock.calls[0][1].headers).get('Idempotency-Key')).toBe('frozen-request-key')
  })
})
