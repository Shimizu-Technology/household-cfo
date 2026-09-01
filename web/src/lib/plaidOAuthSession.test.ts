import { describe, expect, it } from 'vitest'
import {
  clearPlaidOAuthSession,
  completedPlaidOAuthUrl,
  isPlaidOAuthReturn,
  readPlaidOAuthSession,
  savePlaidOAuthSession,
} from './plaidOAuthSession'

class MemoryStorage {
  private values = new Map<string, string>()

  getItem(key: string) {
    return this.values.get(key) ?? null
  }

  setItem(key: string, value: string) {
    this.values.set(key, value)
  }

  removeItem(key: string) {
    this.values.delete(key)
  }
}

describe('Plaid OAuth session storage', () => {
  it('restores a current Link token only for the signed-in user', () => {
    const storage = new MemoryStorage()
    savePlaidOAuthSession({ userId: '42', linkToken: 'link-sandbox-test', updateItemId: 7 }, storage, 1_000)

    expect(readPlaidOAuthSession('42', storage, 2_000)).toMatchObject({ linkToken: 'link-sandbox-test', updateItemId: 7 })
    expect(readPlaidOAuthSession('99', storage, 2_000)).toBeNull()
  })

  it('rejects and removes expired sessions', () => {
    const storage = new MemoryStorage()
    savePlaidOAuthSession({ userId: '42', linkToken: 'link-sandbox-test', updateItemId: null }, storage, 1_000)

    expect(readPlaidOAuthSession('42', storage, 31 * 60 * 1_000)).toBeNull()
  })

  it('clears a matching session after Link exits', () => {
    const storage = new MemoryStorage()
    savePlaidOAuthSession({ userId: '42', linkToken: 'link-sandbox-test', updateItemId: null }, storage, 1_000)

    clearPlaidOAuthSession('42', storage)

    expect(readPlaidOAuthSession('42', storage, 2_000)).toBeNull()
  })

  it('does not throw when browser storage access and cleanup are unavailable', () => {
    const unavailableStorage = {
      getItem: () => { throw new Error('Storage is blocked') },
      setItem: () => { throw new Error('Storage is blocked') },
      removeItem: () => { throw new Error('Storage is blocked') },
    }

    expect(() => readPlaidOAuthSession('42', unavailableStorage)).not.toThrow()
    expect(readPlaidOAuthSession('42', unavailableStorage)).toBeNull()
    expect(() => clearPlaidOAuthSession('42', unavailableStorage)).not.toThrow()
  })
})

describe('Plaid OAuth return URL handling', () => {
  it('detects Plaid OAuth state and removes only that state after completion', () => {
    const href = 'https://householdcfomethod.com/?oauth_state_id=state-123'

    expect(isPlaidOAuthReturn(href)).toBe(true)
    expect(completedPlaidOAuthUrl(href)).toBe('/#My%20Profile')
  })
})
