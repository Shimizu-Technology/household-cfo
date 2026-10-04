import { afterEach, describe, expect, it, vi } from 'vitest'
import { setAuthTokenGetter } from '../api'
import { privacyApi } from './privacyApi'
import { privacyScope } from '../test/privacyFixtures'
afterEach(() => { vi.unstubAllGlobals(); setAuthTokenGetter(null) })
describe('private control transport', () => {
  it('uses authentication no-store and exact private POST fields with idempotency headers', async () => {
    const fetch = vi.fn(async () => new Response('{}')); vi.stubGlobal('fetch', fetch); setAuthTokenGetter(async () => 'fictional-token')
    const identity = { scope: privacyScope, enrollmentId: 100, action: 'support_request' as const, key: 'original-key' }
    const input = { enrollment_id: 100, recipient_user_id: 904, issue_kind: 'technical', message: 'Fictional help', selected_records: [] }
    await privacyApi.mutate(identity, input)
    const [url, options] = fetch.mock.calls[0] as unknown as [string, RequestInit]
    expect(url).toContain('/100/privacy/support_request'); expect(options.cache).toBe('no-store'); expect(options.method).toBe('POST'); expect(JSON.parse(options.body as string)).toEqual(input)
    const headers = new Headers(options.headers); expect(headers.get('Authorization')).toBe('Bearer fictional-token'); expect(headers.get('Idempotency-Key')).toBe('original-key')
    await privacyApi.status(identity)
    expect((fetch.mock.calls[1] as unknown as [string])[0]).toContain('request_status?privacy_action=support_request')
    expect((fetch.mock.calls[1] as unknown as [string])[0]).not.toContain('original-key')
  })
  it('pages exact record candidates and reflection metadata separately and routes erase without financial reads', async () => {
    const fetch = vi.fn(async () => new Response('{}')); vi.stubGlobal('fetch', fetch)
    await privacyApi.candidates(100, 'chat_message', 50); await privacyApi.privacy(100, 70)
    await privacyApi.status({ scope: privacyScope, enrollmentId: 100, action: 'erase', reflectionId: 700, key: 'erase' })
    const urls = fetch.mock.calls.map((call) => (call as unknown as [string])[0]); expect(urls[0]).toContain('record_type=chat_message&cursor=50'); expect(urls[1]).toContain('reflections_cursor=70'); expect(urls[2]).toContain('/daily/reflections/700/erase_status')
  })
})
