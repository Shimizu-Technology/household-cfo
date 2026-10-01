export function createOperationIdempotencyKey() {
  const cryptoApi = globalThis.crypto
  if (typeof cryptoApi?.randomUUID === 'function') {
    const uuid = cryptoApi.randomUUID()
    if (typeof uuid === 'string' && uuid.trim()) return uuid
  }

  if (typeof cryptoApi?.getRandomValues === 'function') {
    const bytes = new Uint8Array(16)
    cryptoApi.getRandomValues(bytes)
    return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')
  }

  return `operation-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
}

export class OperationIdempotencyKeys {
  private readonly pending = new Map<string, string>()

  keyFor(signature: string) {
    const existing = this.pending.get(signature)
    if (existing) return existing

    const created = createOperationIdempotencyKey()
    this.pending.set(signature, created)
    return created
  }

  complete(signature: string) {
    this.pending.delete(signature)
  }
}
