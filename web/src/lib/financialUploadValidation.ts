export const IMAGE_AND_PDF_MAX_BYTES = 12 * 1024 * 1024
export const DATA_AND_DOCUMENT_MAX_BYTES = 20 * 1024 * 1024

export const FINANCIAL_UPLOAD_SIZE_GUIDANCE = 'Images and PDFs up to 12 MB · CSV, Excel, and Word up to 20 MB'

type UploadFile = Pick<File, 'name' | 'size' | 'type'>

type UploadValidationResult =
  | { valid: true; maxBytes: number }
  | { valid: false; reason: 'empty' | 'unsupported' | 'too_large'; message: string; maxBytes: number | null }

const imageAndPdfExtensions = new Set(['pdf', 'jpg', 'jpeg', 'png', 'webp', 'heic', 'heif'])
const dataAndDocumentExtensions = new Set(['csv', 'xls', 'xlsx', 'docx'])
const imageAndPdfContentTypes = new Set([
  'application/pdf',
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/heic',
  'image/heif',
])
const dataAndDocumentContentTypes = new Set([
  'text/csv',
  'application/csv',
  'text/comma-separated-values',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
])

export function validateFinancialUpload(file: UploadFile): UploadValidationResult {
  const filename = file.name.trim() || 'This file'
  const extension = fileExtension(file.name)
  const contentType = file.type.trim().toLowerCase()
  const imageOrPdf = imageAndPdfExtensions.has(extension) || imageAndPdfContentTypes.has(contentType)
  const dataOrDocument = dataAndDocumentExtensions.has(extension) || dataAndDocumentContentTypes.has(contentType)

  if (!imageOrPdf && !dataOrDocument) {
    return {
      valid: false,
      reason: 'unsupported',
      message: `${filename} is not supported. Use PDF, CSV, Excel, Word, JPG, PNG, WEBP, HEIC, or HEIF.`,
      maxBytes: null,
    }
  }

  const maxBytes = imageOrPdf ? IMAGE_AND_PDF_MAX_BYTES : DATA_AND_DOCUMENT_MAX_BYTES
  if (file.size === 0) {
    return {
      valid: false,
      reason: 'empty',
      message: `${filename} is empty. Choose the original file and try again.`,
      maxBytes,
    }
  }

  if (file.size > maxBytes) {
    const limit = imageOrPdf ? 'Images and PDFs can be up to 12 MB.' : 'CSV, Excel, and Word files can be up to 20 MB.'
    return {
      valid: false,
      reason: 'too_large',
      message: `${filename} is too large. ${limit}`,
      maxBytes,
    }
  }

  return { valid: true, maxBytes }
}

function fileExtension(filename: string) {
  return filename.toLowerCase().match(/\.([a-z0-9]+)$/)?.[1] ?? ''
}
