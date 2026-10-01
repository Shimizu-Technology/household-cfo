import { describe, expect, it, vi } from 'vitest'
import { resolveMemoryRequestKey } from './memoryRequestKey'

describe('resolveMemoryRequestKey', () => {
  it('keeps the request key for retries of the unchanged normalized draft', () => {
    const generate = vi.fn().mockReturnValueOnce('first-key').mockReturnValueOnce('second-key')
    const first = resolveMemoryRequestKey(null, {
      category: 'preference', display_value: '  Keep replies concise.  ', sensitivity: 'ordinary',
    }, generate)
    const retry = resolveMemoryRequestKey(first, {
      category: 'preference', display_value: 'Keep replies concise.', sensitivity: 'ordinary',
    }, generate)

    expect(retry).toBe(first)
    expect(retry.requestKey).toBe('first-key')
    expect(generate).toHaveBeenCalledTimes(1)
  })

  it('creates a new request key after the form content changes', () => {
    const generate = vi.fn().mockReturnValueOnce('first-key').mockReturnValueOnce('second-key')
    const first = resolveMemoryRequestKey(null, {
      category: 'preference', display_value: 'Keep replies concise.', sensitivity: 'ordinary',
    }, generate)
    const changed = resolveMemoryRequestKey(first, {
      category: 'coaching_style', display_value: 'Keep replies concise.', sensitivity: 'ordinary',
    }, generate)

    expect(changed.requestKey).toBe('second-key')
    expect(generate).toHaveBeenCalledTimes(2)
  })
})
