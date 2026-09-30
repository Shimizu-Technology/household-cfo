import { describe, expect, it } from 'vitest'
import {
  DATA_AND_DOCUMENT_MAX_BYTES,
  IMAGE_AND_PDF_MAX_BYTES,
  validateFinancialUpload,
} from './financialUploadValidation'

function uploadFile(name: string, type: string, size: number) {
  return { name, type, size } as File
}

describe('financial upload validation', () => {
  it.each([
    ['receipt.jpg', 'image/jpeg'],
    ['statement.pdf', 'application/pdf'],
    ['camera-upload.heic', ''],
  ])('accepts %s at the 12 MiB image and PDF boundary', (name, type) => {
    expect(validateFinancialUpload(uploadFile(name, type, IMAGE_AND_PDF_MAX_BYTES))).toEqual({
      valid: true,
      maxBytes: IMAGE_AND_PDF_MAX_BYTES,
    })
  })

  it('rejects an image one byte beyond the 12 MiB boundary with an actionable message', () => {
    expect(validateFinancialUpload(uploadFile('receipt.png', 'image/png', IMAGE_AND_PDF_MAX_BYTES + 1))).toEqual({
      valid: false,
      reason: 'too_large',
      message: 'receipt.png is too large. Images and PDFs can be up to 12 MB.',
      maxBytes: IMAGE_AND_PDF_MAX_BYTES,
    })
  })

  it.each([
    ['budget.csv', 'text/csv'],
    ['annual-plan.xlsx', ''],
    ['notes.docx', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'],
  ])('accepts %s at the 20 MiB data and document boundary', (name, type) => {
    expect(validateFinancialUpload(uploadFile(name, type, DATA_AND_DOCUMENT_MAX_BYTES))).toEqual({
      valid: true,
      maxBytes: DATA_AND_DOCUMENT_MAX_BYTES,
    })
  })

  it('rejects a spreadsheet one byte beyond the 20 MiB boundary with an actionable message', () => {
    expect(validateFinancialUpload(uploadFile('budget.xlsx', '', DATA_AND_DOCUMENT_MAX_BYTES + 1))).toEqual({
      valid: false,
      reason: 'too_large',
      message: 'budget.xlsx is too large. CSV, Excel, and Word files can be up to 20 MB.',
      maxBytes: DATA_AND_DOCUMENT_MAX_BYTES,
    })
  })

  it('uses the stricter limit when the extension and browser content type conflict', () => {
    const result = validateFinancialUpload(uploadFile('renamed.csv', 'image/png', IMAGE_AND_PDF_MAX_BYTES + 1))
    expect(result).toMatchObject({ valid: false, reason: 'too_large', maxBytes: IMAGE_AND_PDF_MAX_BYTES })
  })

  it('rejects a newly selected zero-byte file with an actionable retry message', () => {
    expect(validateFinancialUpload(uploadFile('saved-receipt.jpg', 'image/jpeg', 0))).toEqual({
      valid: false,
      reason: 'empty',
      message: 'saved-receipt.jpg is empty. Choose the original file and try again.',
      maxBytes: IMAGE_AND_PDF_MAX_BYTES,
    })
  })

  it('rejects unsupported files by both extension and content type', () => {
    expect(validateFinancialUpload(uploadFile('archive.zip', 'application/zip', 100))).toEqual({
      valid: false,
      reason: 'unsupported',
      message: 'archive.zip is not supported. Use PDF, CSV, Excel, Word, JPG, PNG, WEBP, HEIC, or HEIF.',
      maxBytes: null,
    })
  })
})
