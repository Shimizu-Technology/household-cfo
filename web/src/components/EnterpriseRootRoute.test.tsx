// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react'
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
