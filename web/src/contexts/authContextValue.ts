import { createContext, useContext } from 'react'
import type { CurrentUser } from '../api'

export type AuthContextValue = {
  isClerkEnabled: boolean
  authIdentityId: string | null
  isSignedIn: boolean
  isLoading: boolean
  isVerifyingApi: boolean
  currentUser: CurrentUser | null
  activeCoachWorkspaceId: number | null
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
  return useContext(AuthContext)
}
