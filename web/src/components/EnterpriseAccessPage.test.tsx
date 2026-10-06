// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { AuthContext, type AuthContextValue } from '../contexts/authContextValue'
import { EnterpriseAccessPage } from './EnterpriseAccessPage'
import { enterpriseUser } from '../qa/enterpriseFixtures'
const enterpriseSettings = vi.hoisted(() => vi.fn())
vi.mock('./EnterpriseSettings', () => ({ EnterpriseSettings: (props: unknown) => { enterpriseSettings(props); return <p>Company configuration</p> } }))
function auth(overrides: Partial<AuthContextValue> = {}): AuthContextValue {
  return { isClerkEnabled: false, isAuthEnabled: true, authProvider: 'workos', authIdentityId: 'fictional_enterprise_contact', isSignedIn: true, isLoading: false, isVerifyingApi: false, currentUser: enterpriseUser(), activeCoachWorkspaceId: null, authError: null, refreshCurrentUser: async () => undefined, selectCoachWorkspace: () => undefined, ...overrides }
}
afterEach(() => { cleanup(); enterpriseSettings.mockClear() })
it('opens IT configuration for a verified designated contact without a finance role', () => {
  render(<AuthContext.Provider value={auth()}><EnterpriseAccessPage /></AuthContext.Provider>)
  expect(screen.getByText('Company configuration')).toBeTruthy()
  expect(enterpriseSettings).toHaveBeenCalledWith(expect.objectContaining({ currentUser: expect.objectContaining({ is_staff: false, is_admin: false }) }))
})
it.each([{ isLoading: true }, { isVerifyingApi: true }])('withholds configuration until identity and permission verification settle: %j', overrides => {
  render(<AuthContext.Provider value={auth(overrides)}><EnterpriseAccessPage /></AuthContext.Provider>)
  expect(screen.getByRole('heading', { name: 'Checking organization access.' })).toBeTruthy()
  expect(enterpriseSettings).not.toHaveBeenCalled()
})
it('denies a verified participant lacking designated IT access before any enterprise load', () => {
  render(<AuthContext.Provider value={auth({ currentUser: enterpriseUser(false, false) })}><EnterpriseAccessPage /></AuthContext.Provider>)
  expect(screen.getByRole('heading', { name: 'IT configuration access is required.' })).toBeTruthy()
  expect(enterpriseSettings).not.toHaveBeenCalled()
})
it('never mounts configuration after access verification fails', () => {
  render(<AuthContext.Provider value={auth({ authError: 'SSO required for this organization', currentUser: null })}><EnterpriseAccessPage /></AuthContext.Provider>)
  expect(screen.getByRole('heading', { name: 'Organization access could not be verified.' })).toBeTruthy()
  expect(screen.getByText('SSO required for this organization')).toBeTruthy()
  expect(enterpriseSettings).not.toHaveBeenCalled()
})
it('admits platform administrators without implicitly requiring an enterprise membership', () => {
  render(<AuthContext.Provider value={auth({ currentUser: enterpriseUser(true, false) })}><EnterpriseAccessPage /></AuthContext.Provider>)
  expect(screen.getByText('Company configuration')).toBeTruthy()
})
