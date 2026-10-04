import { afterEach, expect, it, vi } from 'vitest'
import {
  fetchDailyContext,
  captureApiOperation,
  sendMiaMessage,
  setActiveCoachWorkspaceId,
  setActiveParticipantCohortId,
  setApiActorIdentity,
  setAuthTokenGetter,
} from './api'

afterEach(() => {
  vi.useRealTimers()
  setApiActorIdentity(null)
  setActiveParticipantCohortId(null)
  setActiveCoachWorkspaceId(null)
  setAuthTokenGetter(null)
  vi.unstubAllGlobals()
})

const changeContext = {
  program: () => setActiveParticipantCohortId(32),
  account: () => setApiActorIdentity('participant-b'),
  workspace: () => setActiveCoachWorkspaceId(21),
  token: () => setAuthTokenGetter(async () => 'different-token'),
  roundtrip: () => { setActiveParticipantCohortId(32); setActiveParticipantCohortId(31) },
}

it.each(Object.keys(changeContext) as (keyof typeof changeContext)[])(
  'stops the original202 Mia operation before another POST when %s changes during its wait',
  async change => {
    vi.useFakeTimers()
    const fetch = vi.fn<typeof globalThis.fetch>().mockResolvedValue(new Response(JSON.stringify({ code: 'mia_request_processing', retry_after_ms: 500 }), { status: 202 }))
    vi.stubGlobal('fetch', fetch)
    setApiActorIdentity('participant-a')
    setAuthTokenGetter(async () => 'fictional-token')
    setActiveParticipantCohortId(31)
    const pending = sendMiaMessage('Fictional prompt', [], true, undefined, undefined, [], 'mia-request-original-context')
    const rejected = expect(pending).rejects.toThrow('Your account or program changed')
    await vi.advanceTimersByTimeAsync(0)
    expect(fetch).toHaveBeenCalledTimes(1)
    changeContext[change]()
    await vi.advanceTimersByTimeAsync(500)
    await rejected
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(new Headers(fetch.mock.calls[0][1]?.headers).get('X-Cohort-Id')).toBe('31')
  },
)

it('continues202 Mia processing in the original scope with the same request body and key', async () => {
  vi.useFakeTimers()
  const processing = () => new Response(JSON.stringify({ code: 'mia_request_processing', retry_after_ms: 500 }), { status: 202 })
  const fetch = vi.fn<typeof globalThis.fetch>().mockResolvedValueOnce(processing()).mockResolvedValueOnce(processing()).mockResolvedValueOnce(new Response(JSON.stringify({ marker: 'fictional-complete' }), { status: 201 }))
  vi.stubGlobal('fetch', fetch)
  setApiActorIdentity('participant-a')
  setAuthTokenGetter(async () => 'fictional-token')
  setActiveParticipantCohortId(31)
  const pending = sendMiaMessage('Fictional prompt', [], true, undefined, undefined, [], 'mia-request-original-context')
  await vi.advanceTimersByTimeAsync(1000)
  expect(await pending).toEqual({ marker: 'fictional-complete' })
  expect(fetch).toHaveBeenCalledTimes(3)
  for (const [, options] of fetch.mock.calls) {
    expect(new Headers(options?.headers).get('X-Cohort-Id')).toBe('31')
    expect(options?.body).toBe(fetch.mock.calls[0][1]?.body)
    expect(JSON.parse(String(options?.body)).request_id).toBe('mia-request-original-context')
  }
})

it('rejects old-scope JSON consumed after response headers have already arrived', async () => {
  let finishBody!: (value: unknown) => void
  const response = new Response('{}')
  vi.spyOn(response, 'json').mockImplementation(() => new Promise(resolve => { finishBody = resolve }))
  const fetch = vi.fn<typeof globalThis.fetch>().mockResolvedValue(response)
  vi.stubGlobal('fetch', fetch)
  setActiveParticipantCohortId(31)
  const pending = fetchDailyContext()
  const rejected = expect(pending).rejects.toThrow('Your account or program changed')
  await vi.waitFor(() => expect(response.json).toHaveBeenCalledTimes(1))
  setActiveParticipantCohortId(32)
  finishBody({ enrollment_id: 9 })
  await rejected
  expect(fetch).toHaveBeenCalledTimes(1)
})

it('exported operation guard remains valid for unchanged context and rejects a return to the original program', () => {
  setApiActorIdentity('participant-a')
  setActiveParticipantCohortId(31)
  const assertOperation = captureApiOperation()
  setActiveParticipantCohortId(31)
  expect(assertOperation).not.toThrow()
  setActiveParticipantCohortId(32)
  setActiveParticipantCohortId(31)
  expect(assertOperation).toThrow('Your account or program changed')
})

it('pins the displayed program before authentication and sends no financial selection in the URL', async () => {
  const fetch = vi.fn<typeof globalThis.fetch>().mockImplementation(async () => new Response('{}'))
  vi.stubGlobal('fetch', fetch)
  setApiActorIdentity('participant-a')
  setAuthTokenGetter(async () => 'fictional-token')
  setActiveParticipantCohortId(31)
  await fetchDailyContext()
  const headers = new Headers(fetch.mock.calls[0][1]?.headers)
  expect(headers.get('Authorization')).toBe('Bearer fictional-token')
  expect(headers.get('X-Cohort-Id')).toBe('31')
  expect(new URL(String(fetch.mock.calls[0][0])).search).toBe('')
})

it.each(['program', 'account', 'workspace', 'token'] as const)(
  'does not dispatch an awaited request after the %s changes',
  async (change) => {
    let resolveToken!: (value: string) => void
    const fetch = vi.fn<typeof globalThis.fetch>().mockImplementation(async () => new Response('{}'))
    vi.stubGlobal('fetch', fetch)
    setApiActorIdentity('participant-a')
    setAuthTokenGetter(
      () =>
        new Promise((resolve) => {
          resolveToken = resolve
        })
    )
    setActiveParticipantCohortId(31)
    const request = fetchDailyContext()
    const rejection = expect(request).rejects.toThrow('Your account or program changed')
    if (change === 'program') setActiveParticipantCohortId(32)
    if (change === 'account') setApiActorIdentity('participant-b')
    if (change === 'workspace') setActiveCoachWorkspaceId(21)
    if (change === 'token') setAuthTokenGetter(async () => 'different-token')
    resolveToken('old-token')
    await rejection
    expect(fetch).not.toHaveBeenCalled()
  }
)

it('rejects a response from the previous program without adopting its context', async () => {
  let resolveResponse!: (value: Response) => void
  const fetch = vi.fn<typeof globalThis.fetch>().mockImplementation(
    () =>
      new Promise<Response>((resolve) => {
        resolveResponse = resolve
      })
  )
  vi.stubGlobal('fetch', fetch)
  setActiveParticipantCohortId(31)
  const request = fetchDailyContext()
  await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(1))
  const rejection = expect(request).rejects.toThrow('Your account or program changed')
  setActiveParticipantCohortId(32)
  resolveResponse(new Response('{"enrollment_id":9}'))
  await rejection
  expect(new Headers(fetch.mock.calls[0][1]?.headers).get('X-Cohort-Id')).toBe('31')
})

it('clears the participant program when changing account or entering a coach workspace', async () => {
  const fetch = vi.fn<typeof globalThis.fetch>().mockImplementation(async () => new Response('{}'))
  vi.stubGlobal('fetch', fetch)
  setApiActorIdentity('participant-a')
  setActiveParticipantCohortId(31)
  setApiActorIdentity('participant-b')
  await fetchDailyContext()
  expect(new Headers(fetch.mock.calls[0][1]?.headers).has('X-Cohort-Id')).toBe(false)
  setActiveParticipantCohortId(32)
  setActiveCoachWorkspaceId(21)
  await fetchDailyContext()
  expect(new Headers(fetch.mock.calls[1][1]?.headers).has('X-Cohort-Id')).toBe(false)
  expect(new Headers(fetch.mock.calls[1][1]?.headers).get('X-Coach-Workspace-Id')).toBe('21')
})
