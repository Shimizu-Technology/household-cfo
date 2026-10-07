// @vitest-environment jsdom
import { cleanup, render } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { AuthContext, type AuthContextValue } from '../contexts/authContextValue'
import { PostHogProvider } from './PostHogProvider'
import { initializeAnalytics, identifyAnalyticsUser, resetAnalytics } from '../lib/analytics'

vi.mock('../lib/analytics', () => ({ initializeAnalytics: vi.fn(), identifyAnalyticsUser: vi.fn(), resetAnalytics: vi.fn() }))

const settled: AuthContextValue = {
  isClerkEnabled: false, isAuthEnabled: true, authProvider: 'workos', authIdentityId: null,
  isSignedIn: false, isLoading: false, isVerifyingApi: false, currentUser: null,
  activeCoachWorkspaceId: null, authError: null,
  refreshCurrentUser: async () => undefined, selectCoachWorkspace: () => undefined,
}
function provider(auth: AuthContextValue) {
  return <AuthContext.Provider value={auth}><PostHogProvider><span>App content</span></PostHogProvider></AuthContext.Provider>
}
beforeEach(() => { vi.clearAllMocks(); window.history.replaceState({}, '', '/') })
afterEach(cleanup)

describe('authentication analytics boundary', () => {
  it('waits for SDK and API verification before initializing capture', () => {
    const view = render(provider({ ...settled, isLoading: true }))
    expect(initializeAnalytics).not.toHaveBeenCalled()
    view.rerender(provider({ ...settled, isVerifyingApi: true }))
    expect(initializeAnalytics).not.toHaveBeenCalled()
    view.rerender(provider(settled))
    expect(initializeAnalytics).toHaveBeenCalledOnce()
  })

  it('never starts capture or identity processing on the credential-bearing callback', () => {
    window.history.replaceState({}, '', '/auth/callback?code=fictional-code&state=fictional-state')
    render(provider(settled))
    expect(initializeAnalytics).not.toHaveBeenCalled()
    expect(identifyAnalyticsUser).not.toHaveBeenCalled()
    expect(resetAnalytics).not.toHaveBeenCalled()
  })
})
