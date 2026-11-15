import { afterEach, expect, it, vi } from 'vitest'
import { encodeFinancialPhoto, financialPhotoSize } from './encodeFinancialPhoto'

afterEach(() => vi.unstubAllGlobals())
it('scales a 24 megapixel phone image before allocating a canvas', () => {
  expect(financialPhotoSize(6000, 4000)).toEqual({ width: 3000, height: 2000 })
  expect(financialPhotoSize(4000, 6000)).toEqual({ width: 2000, height: 3000 })
  expect(financialPhotoSize(640, 480)).toEqual({ width: 640, height: 480 })
})
it('refuses blank pixels and validates the encoded JPEG dimensions', async () => {
  const pixels = new Uint8ClampedArray(32 * 32 * 4)
  const drawImage = vi.fn()
  const convertToBlob = vi.fn(async () => new Blob(['jpeg'], { type: 'image/jpeg' }))
  const allocations: number[][] = []
  vi.stubGlobal('OffscreenCanvas', class {
    constructor(width: number, height: number) { allocations.push([width, height]) }
    getContext() { return { drawImage, getImageData: () => ({ data: pixels }) } }
    convertToBlob = convertToBlob
  })
  const close = vi.fn()
  vi.stubGlobal('createImageBitmap', vi.fn(async () => ({ width: 3000, height: 2000, close })))
  const bitmap = { width: 6000, height: 4000 } as ImageBitmap
  await expect(encodeFinancialPhoto(bitmap)).rejects.toThrow('Blank photo')
  expect(convertToBlob).not.toHaveBeenCalled()
  pixels[4] = 255
  await expect(encodeFinancialPhoto(bitmap)).resolves.toBeInstanceOf(Blob)
  expect(allocations).toEqual([[3000, 2000], [32, 32], [3000, 2000], [32, 32]])
  expect(drawImage).toHaveBeenCalledWith(bitmap, 0, 0, 3000, 2000)
  expect(close).toHaveBeenCalledOnce()
  vi.stubGlobal('createImageBitmap', vi.fn(async () => ({ width: 1, height: 1, close })))
  await expect(encodeFinancialPhoto(bitmap)).rejects.toThrow('Invalid photo dimensions')
})
