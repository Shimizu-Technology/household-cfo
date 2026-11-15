import { afterEach, expect, it, vi } from 'vitest'
import { HEIC_CONVERSION_FAILURE, prepareFinancialUpload } from './prepareFinancialUpload'

const workers: FakeWorker[] = []
class FakeWorker {
  onmessage?: (event: { data: { ready?: boolean; blob?: Blob } }) => void
  onerror?: () => void
  terminate = vi.fn()
  postMessage = vi.fn(() => queueMicrotask(() => this.onmessage?.({ data: { blob: new Blob(['jpeg'], { type: 'image/jpeg' }) } })))
  constructor() { workers.push(this); queueMicrotask(() => this.onmessage?.({ data: { ready: true } })) }
}
afterEach(() => { vi.unstubAllGlobals(); workers.length = 0 })

it('detects HEIF bytes, converts before upload, and always terminates its worker', async () => {
  vi.stubGlobal('Worker', FakeWorker)
  const file = new File(['\0\0\0\x18ftypheic\0\0\0\0heicmif1'], 'photo.heif', { type: 'image/heif' })
  const result = await prepareFinancialUpload(file)
  expect(result.name).toBe('photo.jpg')
  expect(result.type).toBe('image/jpeg')
  expect(workers).toHaveLength(1)
  expect(workers[0].terminate).toHaveBeenCalledOnce()
})

it('refuses a misleading HEIC name before creating a worker', async () => {
  vi.stubGlobal('Worker', FakeWorker)
  await expect(prepareFinancialUpload(new File(['not a photo'], 'photo.heic', { type: 'image/heic' }))).rejects.toThrow(HEIC_CONVERSION_FAILURE)
  expect(workers).toHaveLength(0)
})

it('refuses failed conversion with a way forward and terminates its worker', async () => {
  class FailedWorker extends FakeWorker {
    postMessage = vi.fn(() => queueMicrotask(() => this.onerror?.()))
  }
  vi.stubGlobal('Worker', FailedWorker)
  await expect(prepareFinancialUpload(new File(['\0\0\0\x18ftypheic'], 'photo.heic', { type: 'image/heic' }))).rejects.toThrow('Send a screenshot of the photo, or choose “Most Compatible”')
  expect(workers[0].terminate).toHaveBeenCalledOnce()
})

it('leaves a supported JPEG unchanged and rejects oversize source before decoding', async () => {
  vi.stubGlobal('Worker', FakeWorker)
  const jpeg = new File(['\xff\xd8\xff'], 'receipt.jpg', { type: 'image/jpeg' })
  expect(await prepareFinancialUpload(jpeg)).toBe(jpeg)
  const file = new File(['\0\0\0\x18ftypheic'], 'photo.heic', { type: 'image/heic' })
  Object.defineProperty(file, 'size', { value: 13 * 1024 * 1024 })
  await expect(prepareFinancialUpload(file)).rejects.toThrow('too large')
  expect(workers).toHaveLength(0)
})

it('reports preparation only during photo conversion, never for CSV or PDF', async () => {
  vi.stubGlobal('Worker', FakeWorker)
  const status = vi.fn()
  for (const [name, type] of [['bank.csv', 'text/csv'], ['bank.pdf', 'application/pdf']]) {
    await prepareFinancialUpload(new File(['content'], name, { type }), status)
  }
  expect(status).not.toHaveBeenCalled()
  await prepareFinancialUpload(new File(['\0\0\0\x18ftypheic'], 'photo.heic', { type: 'image/heic' }), status)
  expect(status.mock.calls).toEqual([[true], [false]])
})
