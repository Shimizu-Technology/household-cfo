/** Keep phone canvases below Safari's area limit, even for a 24MP source. */
export function financialPhotoSize(width: number, height: number) {
  if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width <= 0 || height <= 0 || width * height > 64_000_000) throw new Error('Invalid photo size')
  const scale = Math.min(1, 3000 / Math.max(width, height))
  return { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) }
}

export async function encodeFinancialPhoto(bitmap: ImageBitmap): Promise<Blob> {
  const { width, height } = financialPhotoSize(bitmap.width, bitmap.height)
  const canvas = new OffscreenCanvas(width, height)
  const context = canvas.getContext('2d')
  if (!context) throw new Error('Image conversion unavailable')
  context.drawImage(bitmap, 0, 0, width, height)
  // A failed draw can encode as a perfectly valid blank JPEG. Check the pixels
  // before accepting the result; an empty photo carries no readable evidence.
  const sample = new OffscreenCanvas(32, 32).getContext('2d')
  if (!sample) throw new Error('Image validation unavailable')
  sample.drawImage(canvas, 0, 0, 32, 32)
  const pixels = sample.getImageData(0, 0, 32, 32).data
  const first = Array.from(pixels.slice(0, 4))
  if (!pixels.some((value, index) => value !== first[index % 4])) throw new Error('Blank photo')
  const blob = await canvas.convertToBlob({ type: 'image/jpeg', quality: 0.92 })
  if (blob.type !== 'image/jpeg' || !blob.size) throw new Error('Invalid photo')
  const check = await createImageBitmap(blob)
  try {
    if (check.width !== width || check.height !== height) throw new Error('Invalid photo dimensions')
  } finally { check.close() }
  return blob
}
