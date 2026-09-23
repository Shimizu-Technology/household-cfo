import { afterEach, describe, expect, it, vi } from 'vitest'
import { sendMiaMessage, setAuthTokenGetter, uploadDocumentImport } from './api'

const completedPayload = {
  user_message: { id: 1, role: 'user', author: 'You', content: 'Hello', attachments: [], created_at: null },
  assistant_message: { id: 2, role: 'assistant', author: 'Mia', content: 'Verified reply', attachments: [], created_at: null },
}

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
  setAuthTokenGetter(null)
})

describe('Mia request idempotency polling', () => {
  it('polls an in-flight request with the same request ID until the cached response is ready', async () => {
    vi.useFakeTimers()
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({
        status: 'processing',
        code: 'mia_request_processing',
        retry_after_ms: 100,
      }), { status: 202, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify(completedPayload), {
        status: 201,
        headers: { 'Content-Type': 'application/json' },
      }))
    vi.stubGlobal('fetch', fetchMock)

    const responsePromise = sendMiaMessage('Hello', [], true, 2026, 9, [], 'mia-request-stable-1')
    await vi.advanceTimersByTimeAsync(100)
    const response = await responsePromise

    expect(response.assistant_message.content).toBe('Verified reply')
    expect(fetchMock).toHaveBeenCalledTimes(2)
    const requestBodies = fetchMock.mock.calls.map((call) => JSON.parse(String((call[1] as RequestInit).body)))
    expect(requestBodies.map((body) => body.request_id)).toEqual([
      'mia-request-stable-1',
      'mia-request-stable-1',
    ])
  })

  it('surfaces conflicting request reuse instead of silently creating a new turn', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify({
      code: 'mia_request_conflict',
      error: 'This Mia request ID was already used for different content.',
    }), { status: 409, headers: { 'Content-Type': 'application/json' } })))

    await expect(sendMiaMessage('Edited', [], true, 2026, 9, [], 'mia-request-conflict-1'))
      .rejects.toThrow('already used for different content')
  })

  it('surfaces a failed request as a terminal safe error without polling forever', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({
      status: 'failed',
      code: 'mia_request_failed',
      error: 'Mia could not finish that request safely. Your approved household numbers were not changed; send the message again.',
    }), { status: 503, headers: { 'Content-Type': 'application/json' } }))
    vi.stubGlobal('fetch', fetchMock)

    await expect(sendMiaMessage('Hello', [], true, 2026, 9, [], 'mia-request-failed-1'))
      .rejects.toThrow('approved household numbers were not changed')
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })
})

describe('private document upload', () => {
  it('uploads bytes directly to the presigned storage URL before registering the document', async () => {
    const documentImport = { id: 42, status: 'uploaded', filename: 'budget.csv' }
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({
        upload_url: 'https://private-storage.example/upload',
        upload_headers: { 'Content-Type': 'text/csv', 'x-amz-server-side-encryption': 'AES256' },
        upload_token: 'signed-upload-token',
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response('', { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ document_import: documentImport }), { status: 201, headers: { 'Content-Type': 'application/json' } }))
    vi.stubGlobal('fetch', fetchMock)

    const result = await uploadDocumentImport(new File(['type,label,amount\nincome,Pay,5000'], 'budget.csv', { type: 'text/csv' }), 'spreadsheet')

    expect(result.id).toBe(42)
    expect(fetchMock).toHaveBeenCalledTimes(3)
    expect(String(fetchMock.mock.calls[0][0])).toContain('/api/v1/document_imports/presign')
    expect(JSON.parse(String((fetchMock.mock.calls[0][1] as RequestInit).body)).checksum_sha256).toMatch(/^[0-9a-f]{64}$/)
    expect(fetchMock.mock.calls[1][0]).toBe('https://private-storage.example/upload')
    expect((fetchMock.mock.calls[1][1] as RequestInit).body).toBeInstanceOf(File)
    expect((fetchMock.mock.calls[1][1] as RequestInit).headers).toEqual({
      'Content-Type': 'text/csv',
      'x-amz-server-side-encryption': 'AES256',
    })
    expect(String(fetchMock.mock.calls[2][0])).toContain('/api/v1/document_imports/complete')
    expect(JSON.parse(String((fetchMock.mock.calls[2][1] as RequestInit).body))).toEqual({ upload_token: 'signed-upload-token' })
  })
})
