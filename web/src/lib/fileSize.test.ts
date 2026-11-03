import { describe, expect, it } from 'vitest'
import { formatFileSize } from './fileSize'

describe('formatFileSize', () => {
  it('never shows bare bytes', () => {
    expect(formatFileSize(140)).toBe('Under 1 KB')
    expect(formatFileSize(0)).toBe('Under 1 KB')
  })

  it('rounds kilobytes and trims whole megabytes', () => {
    expect(formatFileSize(48_500)).toBe('47 KB')
    expect(formatFileSize(2 * 1024 * 1024)).toBe('2 MB')
    expect(formatFileSize(2.44 * 1024 * 1024)).toBe('2.4 MB')
  })
})
