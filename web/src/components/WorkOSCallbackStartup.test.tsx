// @vitest-environment jsdom
import { cleanup, render } from '@testing-library/react'
import type { ReactNode } from 'react'
import { afterEach, expect, it, vi } from 'vitest'

const startup = vi.hoisted(() => ({ urls: [] as string[], invitation: null as string | null }))
vi.mock('../lib/authConfig', () => ({ authConfiguration: () => ({ provider: 'workos', error: null, devMode: false }) }))
vi.mock('../contexts/AuthContext', () => ({ AuthProvider: ({ children, invitationToken }: { children: ReactNode; invitationToken: string | null }) => {
  startup.invitation = invitationToken
  startup.urls.push(window.location.href)
  return children
} }))
vi.mock('../providers/PostHogProvider', () => ({ PostHogProvider: ({ children }: { children: ReactNode }) => {
  startup.urls.push(window.location.href)
  return children
} }))
vi.mock('./IdentityBoundary', () => ({ IdentityBoundary: ({ children }: { children: ReactNode }) => children }))
vi.mock('./BrandDocument', () => ({ BrandDocument: () => null }))
vi.mock('../contexts/brandContextValue', () => ({ useBrand: () => ({ status: 'ready', brand: {} }) }))
vi.mock('../App', () => ({ default: () => {
  startup.urls.push(window.location.href)
  return <p>Existing workspace</p>
} }))
afterEach(() => { cleanup(); sessionStorage.clear(); window.history.replaceState(null, '', '/') })

it('removes consumed callback credentials before auth, analytics, and financial UI read the URL', async () => {
  window.history.replaceState(null, '', '/?invitation_token=fictional-invite&oauth_state_id=fictional-bank-ref&code=used-code&state=used-state#Review')
  const { default: Root } = await import('../Root')
  expect(window.location.search).toBe('?oauth_state_id=fictional-bank-ref')
  render(<Root />)
  expect(startup.invitation).toBe('fictional-invite')
  expect(startup.urls.length).toBeGreaterThanOrEqual(3)
  expect(startup.urls.every(url => url === `${window.location.origin}/?oauth_state_id=fictional-bank-ref#Review`)).toBe(true)
})
