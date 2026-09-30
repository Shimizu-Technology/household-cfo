import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  ApiRequestError,
  archiveAdminPersona,
  createAdminPersona,
  deleteAdminCohortPersonaAssignment,
  fetchAppData,
  fetchAdminCohortPersonaAssignment,
  fetchAdminPersona,
  fetchAdminPersonaAssignableCohorts,
  fetchAdminPersonas,
  fetchAdminPersonaVersion,
  previewAdminPersona,
  publishAdminPersona,
  restoreAdminPersona,
  rollbackAdminPersonaVersion,
  sendMiaMessage,
  setAuthTokenGetter,
  updateAdminCohortPersonaAssignment,
  updateAdminPersona,
  uploadDocumentImport,
} from './api'

const completedPayload = {
  user_message: { id: 1, role: 'user', author: 'You', content: 'Hello', attachments: [], created_at: null },
  assistant_message: { id: 2, role: 'assistant', author: 'Mia', content: 'Verified reply', attachments: [], created_at: null },
}

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
  setAuthTokenGetter(null)
})

function jsonResponse(payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

describe('Persona Studio API contract', () => {
  it('uses the versioned draft lifecycle endpoints and request envelopes', async () => {
    const persona = { id: 17, name: 'Coach Lani' }
    const preview = { digest: 'preview-digest' }
    const version = { id: 31, number: 1 }
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ personas: [persona] }))
      .mockResolvedValueOnce(jsonResponse({ persona }))
      .mockResolvedValueOnce(jsonResponse({ persona }, 201))
      .mockResolvedValueOnce(jsonResponse({ persona }))
      .mockResolvedValueOnce(jsonResponse({ persona }))
      .mockResolvedValueOnce(jsonResponse({ persona }))
      .mockResolvedValueOnce(jsonResponse({ persona, preview }))
      .mockResolvedValueOnce(jsonResponse({ persona, published_version: version }))
      .mockResolvedValueOnce(jsonResponse({ persona, version }))
      .mockResolvedValueOnce(jsonResponse({ persona, published_version: version }))
    vi.stubGlobal('fetch', fetchMock)
    setAuthTokenGetter(async () => 'staff-token')

    expect(await fetchAdminPersonas()).toEqual([persona])
    expect(await fetchAdminPersona(17)).toEqual(persona)
    expect(await createAdminPersona({ name: 'Coach Lani' })).toEqual(persona)
    expect(await updateAdminPersona(17, { draft_revision: 2, description: 'Clear and kind.' })).toEqual(persona)
    expect(await archiveAdminPersona(17)).toEqual(persona)
    expect(await restoreAdminPersona(17)).toEqual(persona)
    expect(await previewAdminPersona(17, 2, 'Can I afford this?')).toEqual({ persona, preview })
    expect(await publishAdminPersona(17, {
      draft_revision: 2,
      preview_digest: 'preview-digest',
      expected_published_version_id: 30,
    })).toEqual({ persona, published_version: version })
    expect(await fetchAdminPersonaVersion(17, 31)).toEqual({ persona, version })
    expect(await rollbackAdminPersonaVersion(17, 31, {
      draft_revision: 2,
      expected_published_version_id: 32,
    })).toEqual({ persona, published_version: version })

    expect(fetchMock).toHaveBeenCalledTimes(10)
    expect(fetchMock.mock.calls.every((call) => (
      (call[1] as RequestInit).headers as Record<string, string>
    ).Authorization === 'Bearer staff-token')).toBe(true)
    expect(fetchMock.mock.calls.map((call) => String(call[0]).replace(/^.*\/api/, '/api'))).toEqual([
      '/api/v1/admin/personas',
      '/api/v1/admin/personas/17',
      '/api/v1/admin/personas',
      '/api/v1/admin/personas/17',
      '/api/v1/admin/personas/17',
      '/api/v1/admin/personas/17/restore',
      '/api/v1/admin/personas/17/preview',
      '/api/v1/admin/personas/17/publish',
      '/api/v1/admin/personas/17/versions/31',
      '/api/v1/admin/personas/17/versions/31/rollback',
    ])
    expect((fetchMock.mock.calls[3][1] as RequestInit).method).toBe('PATCH')
    expect(fetchMock.mock.calls[2][1]).not.toHaveProperty('signal')
    expect(JSON.parse(String((fetchMock.mock.calls[3][1] as RequestInit).body))).toEqual({
      persona: { draft_revision: 2, description: 'Clear and kind.' },
    })
    expect((fetchMock.mock.calls[4][1] as RequestInit).method).toBe('DELETE')
    expect(JSON.parse(String((fetchMock.mock.calls[6][1] as RequestInit).body))).toEqual({
      preview: { draft_revision: 2, sample_prompt: 'Can I afford this?' },
    })
    expect(JSON.parse(String((fetchMock.mock.calls[7][1] as RequestInit).body))).toEqual({
      publish: {
        draft_revision: 2,
        preview_digest: 'preview-digest',
        expected_published_version_id: 30,
      },
    })
    expect(JSON.parse(String((fetchMock.mock.calls[9][1] as RequestInit).body))).toEqual({
      rollback: { draft_revision: 2, expected_published_version_id: 32 },
    })
  })

  it('uses optimistic assignment values for replace and removal', async () => {
    const assignment = { id: 44, persona: { id: 17, name: 'Coach Lani' } }
    const cohort = { id: 9, persona_assignment: assignment }
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ cohorts: [cohort] }))
      .mockResolvedValueOnce(jsonResponse({ persona_assignment: assignment }))
      .mockResolvedValueOnce(jsonResponse({ persona_assignment: assignment }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
    vi.stubGlobal('fetch', fetchMock)

    expect(await fetchAdminPersonaAssignableCohorts()).toEqual([cohort])
    expect(await fetchAdminCohortPersonaAssignment(9)).toEqual(assignment)
    expect(await updateAdminCohortPersonaAssignment(9, 17, 16)).toEqual(assignment)
    await expect(deleteAdminCohortPersonaAssignment(9, 17)).resolves.toBeUndefined()

    expect((fetchMock.mock.calls[2][1] as RequestInit).method).toBe('PATCH')
    expect(JSON.parse(String((fetchMock.mock.calls[2][1] as RequestInit).body))).toEqual({
      persona_assignment: { persona_id: 17, expected_persona_id: 16 },
    })
    expect((fetchMock.mock.calls[3][1] as RequestInit).method).toBe('DELETE')
    expect(JSON.parse(String((fetchMock.mock.calls[3][1] as RequestInit).body))).toEqual({
      persona_assignment: { expected_persona_id: 17 },
    })
  })

  it('preserves structured status, code, errors, and conflicts on an Error subclass', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse({
      error: 'This cohort conflicts with another assignment.',
      errors: ['Reload the current assignment.'],
      code: 'persona_assignment_conflict',
      conflicts: [{ participant_count: 3 }],
    }, 409)))

    const error = await updateAdminCohortPersonaAssignment(9, 17, null).catch((reason: unknown) => reason)

    expect(error).toBeInstanceOf(Error)
    expect(error).toBeInstanceOf(ApiRequestError)
    expect(error).toMatchObject({
      message: 'This cohort conflicts with another assignment.',
      status: 409,
      code: 'persona_assignment_conflict',
      errors: ['Reload the current assignment.'],
      conflicts: [{ participant_count: 3 }],
    })
  })
})

describe('safe read deadlines', () => {
  it('ends a stalled workspace read so the loading screen can offer a retry', async () => {
    vi.useFakeTimers()
    let requestSignal: AbortSignal | null | undefined
    const fetchMock = vi.fn((_input: RequestInfo | URL, init?: RequestInit) => {
      requestSignal = init?.signal
      return new Promise<Response>(() => undefined)
    })
    vi.stubGlobal('fetch', fetchMock)

    const workspaceRequest = fetchAppData(true)
    const result = expect(workspaceRequest).rejects.toThrow('This request took too long. Please try again.')
    await vi.advanceTimersByTimeAsync(30_000)
    await result

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(requestSignal?.aborted).toBe(true)
  })
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

  it('ends a stalled request and keeps the caller request ID available for a safe retry', async () => {
    vi.useFakeTimers()
    const fetchMock = vi.fn()
      .mockImplementationOnce((_input: RequestInfo | URL, init?: RequestInit) => new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true })
      }))
      .mockResolvedValueOnce(jsonResponse(completedPayload, 201))
    vi.stubGlobal('fetch', fetchMock)

    const firstAttempt = sendMiaMessage('Hello', [], true, 2026, 9, [], 'mia-request-timeout-1')
    const firstResult = expect(firstAttempt).rejects.toThrow('Mia took too long to finish this request. Please try again.')
    await vi.advanceTimersByTimeAsync(90_000)
    await firstResult

    await expect(sendMiaMessage('Hello', [], true, 2026, 9, [], 'mia-request-timeout-1'))
      .resolves.toMatchObject({ assistant_message: { content: 'Verified reply' } })

    const requestBodies = fetchMock.mock.calls.map((call) => JSON.parse(String((call[1] as RequestInit).body)))
    expect(requestBodies.map((body) => body.request_id)).toEqual([
      'mia-request-timeout-1',
      'mia-request-timeout-1',
    ])
  })

  it('includes stalled auth token acquisition in the Mia request deadline', async () => {
    vi.useFakeTimers()
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    setAuthTokenGetter(() => new Promise<string | null>(() => undefined))

    const request = sendMiaMessage('Hello', [], true, 2026, 9, [], 'mia-request-auth-timeout-1')
    const result = expect(request).rejects.toThrow('Mia took too long to finish this request. Please try again.')
    await vi.advanceTimersByTimeAsync(90_000)
    await result

    expect(fetchMock).not.toHaveBeenCalled()
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
    expect(JSON.parse(String((fetchMock.mock.calls[0][1] as RequestInit).body)).checksum_sha256).toBe('4cfe69bb4e953d676b7517da64886344a4b1d09db8a03c7852e506f4d09b53ce')
    expect(fetchMock.mock.calls[1][0]).toBe('https://private-storage.example/upload')
    expect((fetchMock.mock.calls[1][1] as RequestInit).method).toBe('PUT')
    expect((fetchMock.mock.calls[1][1] as RequestInit).body).toBeInstanceOf(File)
    expect((fetchMock.mock.calls[1][1] as RequestInit).headers).toEqual({
      'Content-Type': 'text/csv',
      'x-amz-server-side-encryption': 'AES256',
    })
    expect(String(fetchMock.mock.calls[2][0])).toContain('/api/v1/document_imports/complete')
    expect(JSON.parse(String((fetchMock.mock.calls[2][1] as RequestInit).body))).toEqual({ upload_token: 'signed-upload-token' })
  })

  it('uses the canonical extension MIME type when the browser reports a nonstandard CSV type', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({
        upload_url: 'https://private-storage.example/upload',
        upload_headers: { 'Content-Type': 'text/csv' },
        upload_token: 'signed-upload-token',
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response('', { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ document_import: { id: 43 } }), { status: 201, headers: { 'Content-Type': 'application/json' } }))
    vi.stubGlobal('fetch', fetchMock)

    await uploadDocumentImport(new File(['amount\n10'], 'budget.csv', { type: 'text/comma-separated-values' }), 'spreadsheet')

    const presignBody = JSON.parse(String((fetchMock.mock.calls[0][1] as RequestInit).body))
    expect(presignBody.content_type).toBe('text/csv')
    expect((fetchMock.mock.calls[1][1] as RequestInit).headers).toEqual({ 'Content-Type': 'text/csv' })
  })
})
