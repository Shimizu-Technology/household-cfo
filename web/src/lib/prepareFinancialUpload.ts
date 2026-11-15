import { validateFinancialUpload } from './financialUploadValidation'

export const HEIC_CONVERSION_FAILURE = 'We couldn’t convert this photo. Send a screenshot of the photo, or choose “Most Compatible” in your camera’s format settings and take a new photo.'

// Inspect the ISO base-media header, rather than trusting a filename or MIME.
export async function prepareFinancialUpload(file: File, onConversion?: (converting: boolean) => void): Promise<File> {
  const validation = validateFinancialUpload(file)
  if (!validation.valid) throw new Error(validation.message)
  const bytes = new Uint8Array(await file.slice(0, 64).arrayBuffer())
  const header = String.fromCharCode(...bytes)
  const heif = header.slice(4, 8) === 'ftyp' && /heic|heix|hevc|hevx|heim|heis|mif1|msf1/.test(header.slice(8))
  const declared = /\.hei[cf]$/i.test(file.name) || /^image\/hei[cf]$/i.test(file.type)
  if (!heif) {
    if (declared) throw new Error(HEIC_CONVERSION_FAILURE)
    return file
  }
  // Decoding stays on this device in an owned worker. Terminate on every exit,
  // including timeout; neither the original nor the pixels leave for conversion.
  onConversion?.(true)
  try {
    const converted = await new Promise<Blob>((resolve, reject) => {
      const worker = new Worker(new URL('./heicConversion.worker.ts', import.meta.url), { type: 'module' })
      const finish = (blob?: Blob) => {
        clearTimeout(timeout)
        worker.terminate()
        if (blob?.size) resolve(blob)
        else reject(new Error(HEIC_CONVERSION_FAILURE))
      }
      let timeout = setTimeout(() => finish(), 120_000)
      worker.onmessage = (event: MessageEvent<{ ready?: boolean; blob?: Blob }>) => {
        if (event.data.ready) {
          clearTimeout(timeout)
          timeout = setTimeout(() => finish(), 30_000)
          worker.postMessage(file)
        } else finish(event.data.blob)
      }
      worker.onerror = () => finish()
    }).catch(() => { throw new Error(HEIC_CONVERSION_FAILURE) })
    const output = new File([converted], file.name.replace(/\.[^.]+$/, '') + '.jpg', { type: 'image/jpeg', lastModified: file.lastModified })
    const result = validateFinancialUpload(output)
    if (!result.valid) throw new Error(result.message)
    return output
  } finally { onConversion?.(false) }
}
