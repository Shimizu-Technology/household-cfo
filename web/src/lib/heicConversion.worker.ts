/// <reference lib="webworker" />
import { heicTo } from 'heic-to/csp'
import { encodeFinancialPhoto } from './encodeFinancialPhoto'

self.onmessage = async (event: MessageEvent<File>) => {
  let bitmap: ImageBitmap | undefined
  try {
    bitmap = await heicTo({ blob: event.data, type: 'bitmap' })
    self.postMessage({ blob: await encodeFinancialPhoto(bitmap) })
  } catch {
    self.postMessage({})
  } finally {
    bitmap?.close()
  }
}
// Static decoder imports have finished downloading before this signal. The
// conversion deadline starts here, rather than penalising a slow connection.
self.postMessage({ ready: true })
