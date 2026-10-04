import { afterEach, expect, it, vi } from 'vitest'
import { setActiveCoachWorkspaceId, setActiveParticipantCohortId, setApiActorIdentity, setAuthTokenGetter, uploadDocumentImport } from './api'

afterEach(() => {
  setApiActorIdentity(null)
  setActiveParticipantCohortId(null)
  setActiveCoachWorkspaceId(null)
  setAuthTokenGetter(null)
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
})

const changes = {
  program: () => setActiveParticipantCohortId(32),
  account: () => setApiActorIdentity('participant-b'),
  workspace: () => setActiveCoachWorkspaceId(21),
  roundtrip: () => { setActiveParticipantCohortId(32); setActiveParticipantCohortId(31) },
}
const presign = () => new Response(JSON.stringify({ upload_url: 'https://private-storage.example/fictional-upload', upload_headers: { 'Content-Type': 'text/csv' }, upload_token: 'fictional-original-token' }))
const completed = () => new Response(JSON.stringify({ document_import: { id: 42, filename: 'fictional.csv', status: 'uploaded' } }), { status: 201 })
function originalContext() {
  setApiActorIdentity('participant-a')
  setAuthTokenGetter(async () => 'fictional-token')
  setActiveParticipantCohortId(31)
}

it.each(Object.keys(changes) as (keyof typeof changes)[])(
  'does not sign or upload a file when %s changes while its checksum is pending',
  async change => {
    originalContext()
    const file = new File(['fictional'], 'fictional.csv', { type: 'text/csv' })
    let finishBytes!: (value: ArrayBuffer) => void
    const bytes = vi.spyOn(file, 'arrayBuffer').mockImplementation(() => new Promise(resolve => { finishBytes = resolve }))
    const fetch = vi.fn<typeof globalThis.fetch>().mockResolvedValue(presign())
    vi.stubGlobal('fetch', fetch)
    const pending = uploadDocumentImport(file, 'spreadsheet', 'mia', 'Fictional original prompt')
    const rejected = expect(pending).rejects.toThrow('Your account or program changed')
    await vi.waitFor(() => expect(bytes).toHaveBeenCalledTimes(1))
    changes[change]()
    finishBytes(new Uint8Array([1]).buffer)
    await rejected
    expect(fetch).not.toHaveBeenCalled()
  },
)

it.each(Object.keys(changes) as (keyof typeof changes)[])(
  'does not register an original upload under a new context when %s changes during storage PUT',
  async change => {
    originalContext()
    let finishPut!: (value: Response) => void
    const fetch = vi.fn<typeof globalThis.fetch>()
      .mockResolvedValueOnce(presign())
      .mockImplementationOnce(() => new Promise(resolve => { finishPut = resolve }))
      .mockResolvedValueOnce(completed())
    vi.stubGlobal('fetch', fetch)
    const pending = uploadDocumentImport(new File(['fictional'], 'fictional.csv', { type: 'text/csv' }), 'spreadsheet', 'mia')
    const rejected = expect(pending).rejects.toThrow('Your account or program changed')
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(2))
    expect(fetch.mock.calls[1][0]).toBe('https://private-storage.example/fictional-upload')
    changes[change]()
    finishPut(new Response('', { status: 200 }))
    await rejected
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(new Headers(fetch.mock.calls[0][1]?.headers).get('X-Cohort-Id')).toBe('31')
    expect(new Headers(fetch.mock.calls[1][1]?.headers).has('Authorization')).toBe(false)
  },
)

it('completes the same-context checksum, signing, private PUT and registration in order', async () => {
  originalContext()
  const fetch = vi.fn<typeof globalThis.fetch>().mockResolvedValueOnce(presign()).mockResolvedValueOnce(new Response('', { status: 200 })).mockResolvedValueOnce(completed())
  vi.stubGlobal('fetch', fetch)
  const file = new File(['fictional'], 'fictional.csv', { type: 'text/csv' })
  expect((await uploadDocumentImport(file, 'spreadsheet', 'mia', 'Fictional original prompt')).id).toBe(42)
  expect(fetch).toHaveBeenCalledTimes(3)
  expect(String(fetch.mock.calls[0][0])).toContain('/document_imports/presign')
  expect(fetch.mock.calls[1][0]).toBe('https://private-storage.example/fictional-upload')
  expect(String(fetch.mock.calls[2][0])).toContain('/document_imports/complete')
  for (const index of [0, 2]) {
    const headers = new Headers(fetch.mock.calls[index][1]?.headers)
    expect(headers.get('X-Cohort-Id')).toBe('31')
    expect(headers.get('Authorization')).toBe('Bearer fictional-token')
  }
  expect(fetch.mock.calls[1][1]?.body).toBe(file)
  expect(new Headers(fetch.mock.calls[1][1]?.headers).has('X-Cohort-Id')).toBe(false)
  expect(JSON.parse(String(fetch.mock.calls[2][1]?.body))).toEqual({ upload_token: 'fictional-original-token' })
})
