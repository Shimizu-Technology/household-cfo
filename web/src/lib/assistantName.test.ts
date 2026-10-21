import { describe, expect, it } from 'vitest'
import { shortAssistantName } from './assistantName'

describe('shortAssistantName', () => {
  it('drops the program label coaches add to the assistant name', () => {
    expect(shortAssistantName('Mia for Mrs. Mel BOG')).toBe('Mia')
    expect(shortAssistantName('  Mia   FOR   BOG pilot ')).toBe('Mia')
    expect(shortAssistantName('Mia (BOG pilot)')).toBe('Mia')
    expect(shortAssistantName('Mia - BOG')).toBe('Mia')
    expect(shortAssistantName('Mia — Bank of Guam')).toBe('Mia')
    expect(shortAssistantName('Mia | savings')).toBe('Mia')
  })

  it('keeps names that are already a name', () => {
    expect(shortAssistantName('Mia')).toBe('Mia')
    expect(shortAssistantName('Coach Lila')).toBe('Coach Lila')
    expect(shortAssistantName('Mia-Rose')).toBe('Mia-Rose')
    expect(shortAssistantName('Fortune')).toBe('Fortune')
  })

  it('falls back to the full name when no usable short part exists', () => {
    expect(shortAssistantName('(BOG) Mia')).toBe('(BOG) Mia')
    expect(shortAssistantName('')).toBe('')
    expect(shortAssistantName(null)).toBe('')
  })
})
