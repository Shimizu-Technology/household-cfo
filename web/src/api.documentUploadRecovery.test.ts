import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { setApiActorIdentity, setAuthTokenGetter, uploadDocumentImport } from './api'
import { participantErrorMessage } from './lib/participantErrorMessage'

beforeEach(() => {
  vi.resetAllMocks()
  setApiActorIdentity('synthetic-upload-participant')
  setAuthTokenGetter(async () => 'synthetic-token')
})
afterEach(() => {
  setApiActorIdentity(null)
  setAuthTokenGetter(null)
  vi.useRealTimers()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
})
const signedUpload = () => new Response(JSON.stringify({ upload_url: 'https://storage.example/synthetic', upload_headers: {}, upload_token: 'synthetic-token' }))
const file = () => new File(['Date,Description,Debit\n2026-09-01,Payless,15'], 'synthetic.csv', { type: 'text/csv' })

it.each([403, 500, 503])('describes storage refusal %s without blaming a participant connection or exposing a status', async status => {
  const fetch = vi.fn().mockResolvedValueOnce(signedUpload()).mockResolvedValueOnce(new Response('', { status }))
  vi.stubGlobal('fetch', fetch)
  const error = await uploadDocumentImport(file(), 'statement').catch(error => error)
  expect(participantErrorMessage(error, 'Fallback')).toBe('Our file storage couldn’t accept your file. It is still selected. Try again in a few minutes; if it keeps happening, contact your program team.')
  expect(fetch).toHaveBeenCalledTimes(2)
})
it.each([true, false])('distinguishes storage connection uncertainty from known offline state (%s)', async online => {
  vi.stubGlobal('navigator', { onLine: online })
  vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(signedUpload()).mockRejectedValueOnce(new TypeError('Failed to fetch')))
  const error = await uploadDocumentImport(file(), 'statement').catch(error => error)
  expect(participantErrorMessage(error, 'Fallback')).toContain(online ? 'We couldn’t connect to our file storage.' : 'You appear to be offline.')
  expect(error.message).toContain('still selected')
})
it('bounds stalled storage requests even when fetch ignores abort', async () => {
  vi.useFakeTimers()
  const fetch = vi.fn().mockResolvedValueOnce(signedUpload()).mockImplementationOnce(() => new Promise(() => {}))
  vi.stubGlobal('fetch', fetch)
  const pending = uploadDocumentImport(file(), 'statement')
  const rejection = expect(pending).rejects.toThrow('Your file took too long to upload. It is still selected; try again.')
  await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(2))
  await vi.advanceTimersByTimeAsync(180_001)
  await rejection
  expect(fetch.mock.calls[1][1].signal.aborted).toBe(true)
  expect(fetch).toHaveBeenCalledTimes(2)
})
it('keeps the storage-unavailable code safe for the participant', async () => {
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify({ errors: ['Internal storage detail'], code: 'storage_unavailable' }), { status: 503 })))
  const error = await uploadDocumentImport(file(), 'statement').catch(error => error)
  expect(participantErrorMessage(error, 'Fallback')).toBe('File storage is unavailable for a moment. Try again in a few minutes.')
})
