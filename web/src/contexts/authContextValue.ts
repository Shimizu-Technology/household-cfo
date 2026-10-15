import { createContext, useContext } from 'react'
import type { CurrentUser } from '../api'
import type { AuthProviderName } from '../lib/authConfig'

export type AuthSignInOptions = { organizationId?: string; invitationToken?: string; returnTo?: string }

export type AuthContextValue = {
  isAuthEnabled: boolean
  authProvider?: AuthProviderName | 'preview'
  signIn?: (options?: AuthSignInOptions) => Promise<void>
  signUp?: (options?: AuthSignInOptions) => Promise<void>
  authErrorStatus?: number | null
  authIdentityId: string | null
  isSignedIn: boolean
  isLoading: boolean
  isVerifyingApi: boolean
  currentUser: CurrentUser | null
  activeCoachWorkspaceId: number | null
  authRecoveryRequired?: boolean
  authError: string | null
  refreshCurrentUser: () => Promise<void>
  selectCoachWorkspace: (workspaceId: number | null) => void
  signOut?: () => Promise<void>
}

export const AuthContext = createContext<AuthContextValue>({
  isAuthEnabled: false,
  authIdentityId: null,
  isSignedIn: false,
  isLoading: false,
  isVerifyingApi: false,
  currentUser: null,
  activeCoachWorkspaceId: null,
  authError: null,
  refreshCurrentUser: async () => undefined,
  selectCoachWorkspace: () => undefined,
})

export function useAuthContext() {
  const value = useContext(AuthContext)
  return { ...value, authProvider: value.authProvider ?? (value.isAuthEnabled ? 'workos' : 'preview') }
}
