// @vitest-environment jsdom
import { act, cleanup, render, screen } from '@testing-library/react'
import type { ReactNode } from 'react'
import { afterEach, expect, it, vi } from 'vitest'
const financialBootstrap = vi.hoisted(() => vi.fn())
vi.mock('../lib/authConfig', () => ({ authConfiguration: () => ({ provider: 'preview', error: null, devMode: false }) }))
vi.mock('../contexts/AuthContext', () => ({ AuthProvider: ({ children }: { children: ReactNode }) => children }))
vi.mock('../providers/PostHogProvider', () => ({ PostHogProvider: ({ children }: { children: ReactNode }) => children }))
vi.mock('./IdentityBoundary', () => ({ IdentityBoundary: ({ children }: { children: ReactNode }) => children }))
vi.mock('./BrandDocument', () => ({ BrandDocument: () => null }))
vi.mock('../contexts/brandContextValue', () => ({ useBrand: () => ({ status: 'ready', brand: {} }) }))
vi.mock('./EnterpriseAccessPage', () => ({ EnterpriseAccessPage: () => <p>Organization configuration route</p> }))
vi.mock('../App', () => ({ default: () => { financialBootstrap(); return <p>Finance route</p> } }))
import Root from '../Root'
import { restoreAuthReturn } from '../lib/authNavigation'
afterEach(() => { cleanup(); financialBootstrap.mockClear(); window.history.replaceState(null, '', '/') })
it.each(['/organization-access', '/?enterprise=1'])('routes %s to configuration before mounting the finance application', route => {
  window.history.replaceState(null, '', route)
  render(<Root />)
  expect(screen.getByText('Organization configuration route')).toBeTruthy()
  expect(financialBootstrap).not.toHaveBeenCalled()
})
it('leaves ordinary root navigation connected to the existing finance application', () => {
  render(<Root />)
  expect(screen.getByText('Finance route')).toBeTruthy()
  expect(financialBootstrap).toHaveBeenCalledOnce()
})

it('switches callback navigation to organization access before a subsequent auth render can load finance', async () => {
  window.history.replaceState(null, '', '/auth/callback?code=fictional-callback-code')
  render(<Root />)
  expect(screen.getByText('Finance route')).toBeTruthy()
  const initialFinanceRenders = financialBootstrap.mock.calls.length
  await act(async () => restoreAuthReturn({ state: { returnTo: '/organization-access' } }))
  expect(window.location.pathname).toBe('/organization-access')
  expect(screen.getByText('Organization configuration route')).toBeTruthy()
  expect(screen.queryByText('Finance route')).toBeNull()
  expect(financialBootstrap).toHaveBeenCalledTimes(initialFinanceRenders)
})
it('follows browser history back to organization configuration instead of keeping the finance route mounted', async () => {
  render(<Root />)
  const initialFinanceRenders = financialBootstrap.mock.calls.length
  await act(async () => {
    window.history.replaceState(null, '', '/?enterprise=1')
    window.dispatchEvent(new PopStateEvent('popstate'))
  })
  expect(screen.getByText('Organization configuration route')).toBeTruthy()
  expect(screen.queryByText('Finance route')).toBeNull()
  expect(financialBootstrap).toHaveBeenCalledTimes(initialFinanceRenders)
})
