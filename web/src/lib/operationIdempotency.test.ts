import { afterEach, describe, expect, it, vi } from 'vitest'
import { budgetAllocationOperationSignature, OperationIdempotencyKeys } from './operationIdempotency'

afterEach(() => vi.unstubAllGlobals())

describe('OperationIdempotencyKeys', () => {
  it('reuses one key across retries and concurrent submissions of the same attempt', () => {
    const randomUUID = vi.fn().mockReturnValueOnce('attempt-one').mockReturnValueOnce('attempt-two')
    vi.stubGlobal('crypto', { randomUUID })
    const keys = new OperationIdempotencyKeys()

    expect(keys.keyFor('create:{"name":"Dining"}')).toBe('attempt-one')
    expect(keys.keyFor('create:{"name":"Dining"}')).toBe('attempt-one')
    expect(randomUUID).toHaveBeenCalledTimes(1)

    keys.complete('create:{"name":"Dining"}')
    expect(keys.keyFor('create:{"name":"Dining"}')).toBe('attempt-two')
  })

  it('uses different keys when the operation input changes', () => {
    const keys = new OperationIdempotencyKeys()
    expect(keys.keyFor('allocation:1:500')).not.toBe(keys.keyFor('allocation:1:600'))
  })

  it('binds allocation attempts to the selected budget year', () => {
    expect(budgetAllocationOperationSignature(2026, 44, 325))
      .not.toBe(budgetAllocationOperationSignature(2027, 44, 325))
    expect(budgetAllocationOperationSignature(2026, 44, 325)).toBe('set-allocation:2026:44:325')
  })

  it('falls back to random bytes when randomUUID unexpectedly returns blank', () => {
    vi.stubGlobal('crypto', {
      randomUUID: () => '',
      getRandomValues: (bytes: Uint8Array) => bytes.fill(7),
    })

    expect(new OperationIdempotencyKeys().keyFor('category:1')).toBe('07070707070707070707070707070707')
  })

  it('releases a successful batch key while retaining the failed request key for retry', () => {
    const keys = new OperationIdempotencyKeys()
    const first = keys.keyFor('category:1')
    const second = keys.keyFor('allocation:2')

    keys.complete('category:1')
    expect(keys.keyFor('category:1')).not.toBe(first)
    expect(keys.keyFor('allocation:2')).toBe(second)
  })
})
