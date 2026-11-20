// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest'
import { localTestAuth } from './localTestAuth'
afterEach(() => vi.unstubAllEnvs())
it('keeps test identities out of ordinary production builds', () => {
  vi.stubEnv('DEV', false); vi.stubEnv('VITE_E2E_AUTH', 'true'); vi.stubEnv('VITE_LOCAL_STACK', '')
  expect(localTestAuth()).toBe(false)
})
it('requires both page and API to be loopback for an isolated production build', () => {
  vi.stubEnv('DEV', false); vi.stubEnv('VITE_E2E_AUTH', 'true'); vi.stubEnv('VITE_LOCAL_STACK', 'true')
  vi.stubEnv('VITE_API_BASE_URL', 'https://example.com')
  expect(localTestAuth()).toBe(false)
  vi.stubEnv('VITE_API_BASE_URL', 'http://127.0.0.1:3429')
  expect(localTestAuth()).toBe(true)
  vi.stubEnv('VITE_E2E_AUTH', '')
  expect(localTestAuth()).toBe(false)
})
