import { createContext, useContext } from 'react'
import type { CurrentUser } from '../api'
import type { AuthProviderName } from '../lib/authConfig'

export type AuthContextValue = {
  /** Transitional compatibility for existing local QA fixtures. */
  isClerkEnabled: boolean
  isAuthEnabled?: boolean
  authProvider?: AuthProviderName | 'preview'
  signIn?: () => Promise<void>
  signUp?: () => Promise<void>
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
  isClerkEnabled: false,
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
  return { ...value, isAuthEnabled: value.isAuthEnabled ?? value.isClerkEnabled, authProvider: value.authProvider ?? (value.isClerkEnabled ? 'clerk' : 'preview') }
}
