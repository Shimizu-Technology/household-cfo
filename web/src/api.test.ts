import { afterEach, describe, expect, it, vi } from 'vitest'
import { sendMiaMessage, setAuthTokenGetter } from './api'

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
