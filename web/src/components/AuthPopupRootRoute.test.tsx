// @vitest-environment jsdom
import { cleanup, render } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
const mounted = vi.hoisted(() => ({ finance: vi.fn(), analytics: vi.fn(), auth: vi.fn() }))
vi.mock('../lib/authConfig', () => ({ authConfiguration: () => ({ provider: 'workos', error: null, clientId: 'client_FICTIONAL' }) }))
vi.mock('../contexts/AuthContext', () => ({ AuthProvider: () => { mounted.auth(); return null } }))
vi.mock('../providers/PostHogProvider', () => ({ PostHogProvider: () => { mounted.analytics(); return null } }))
vi.mock('./BrandDocument', () => ({ BrandDocument: () => null }))
vi.mock('../contexts/brandContextValue', () => ({ useBrand: () => ({ status: 'ready', brand: { organization_name: 'Fictional program' } }) }))
vi.mock('../App', () => ({ default: () => { mounted.finance(); return null } }))
afterEach(() => { cleanup(); vi.resetModules(); vi.unstubAllGlobals(); window.history.replaceState(null, '', '/') })
it('handles the popup completion before auth, analytics, or finance providers mount', async () => {
  window.history.replaceState(null, '', '/login/complete')
  vi.stubGlobal('opener', null); vi.stubGlobal('close', vi.fn())
  const { default: Root } = await import('../Root')
  render(<Root />)
  expect(mounted.auth).not.toHaveBeenCalled()
  expect(mounted.analytics).not.toHaveBeenCalled()
  expect(mounted.finance).not.toHaveBeenCalled()
})
