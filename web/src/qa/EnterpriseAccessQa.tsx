import { useMemo, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { AuthContext, type AuthContextValue } from '../contexts/authContextValue'
import { BrandContext, NEUTRAL_BRAND } from '../contexts/brandContextValue'
import { EnterpriseAccessPage } from '../components/EnterpriseAccessPage'
import { EnterpriseSettings } from '../components/EnterpriseSettings'
import { enterpriseUser } from './enterpriseFixtures'
import { setAuthTokenGetter } from '../api'
import '../index.css'
import '../App.css'
import '../dialogViewport.css'
const params = new URLSearchParams(window.location.search)
const mode = params.get('mode') ?? 'it'
export function EnterpriseAccessQa() {
  const [open, setOpen] = useState(false)
  const user = useMemo(() => enterpriseUser(mode === 'admin', mode !== 'forbidden'), [])
  const auth = useMemo<AuthContextValue>(() => ({
    isClerkEnabled: false, isAuthEnabled: true, authProvider: 'workos', authIdentityId: user.auth_subject ?? null,
    isSignedIn: mode !== 'signed-out', isLoading: mode === 'pending', isVerifyingApi: mode === 'pending',
    currentUser: mode === 'error' || mode === 'pending' || mode === 'signed-out' ? null : user,
    activeCoachWorkspaceId: null, authError: mode === 'error' ? 'Company SSO is required for this account.' : null,
    refreshCurrentUser: async () => undefined, selectCoachWorkspace: () => undefined,
    signIn: async () => undefined, signOut: async () => undefined,
  }), [user])
  const brand = useMemo(() => ({ brand: { ...NEUTRAL_BRAND, product_name: 'Household CFO', organization_name: 'Fictional organization access QA' }, assistantName: 'Mia', hostname: 'localhost', source: 'qa', status: 'ready' as const, error: null, retry: () => undefined, isRuntimeBrand: false }), [])
  return <BrandContext.Provider value={brand}><AuthContext.Provider value={auth}>
    {params.get('surface') === 'dialog' ? <main className="app">
      <h1>Development QA · fictional account</h1>
      <button onClick={() => setOpen(true)}>Open organization settings</button>
      {open && <EnterpriseSettings currentUser={user} onClose={() => setOpen(false)} />}
    </main> : <EnterpriseAccessPage />}
  </AuthContext.Provider></BrandContext.Provider>
}
// This entry is served only for opted-in development QA; no synthetic auth is
// mounted by the production application or its build entry.
if (import.meta.env.DEV && import.meta.env.VITE_E2E_AUTH === 'true') {
  setAuthTokenGetter(async () => 'fictional-enterprise-qa-token')
  createRoot(document.getElementById('root')!).render(<EnterpriseAccessQa />)
}
