/// <reference lib="webworker" />
import { heicTo } from 'heic-to/csp'

self.onmessage = async (event: MessageEvent<File>) => {
  let bitmap: ImageBitmap | undefined
  try {
    bitmap = await heicTo({ blob: event.data, type: 'bitmap' })
    if (bitmap.width * bitmap.height > 32_000_000) throw new Error('Photo too large')
    const canvas = new OffscreenCanvas(bitmap.width, bitmap.height)
    const context = canvas.getContext('2d')
    if (!context) throw new Error('Image conversion unavailable')
    context.drawImage(bitmap, 0, 0)
    const blob = await canvas.convertToBlob({ type: 'image/jpeg', quality: 0.92 })
    self.postMessage({ blob })
  } catch {
    self.postMessage({})
  } finally {
    bitmap?.close()
  }
}
