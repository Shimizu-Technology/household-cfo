import { createContext, useContext } from 'react'
import type { CurrentUser } from '../api'

export type AuthContextValue = {
  isClerkEnabled: boolean
  isSignedIn: boolean
  isLoading: boolean
  isVerifyingApi: boolean
  currentUser: CurrentUser | null
  authError: string | null
  refreshCurrentUser: () => Promise<void>
  signOut?: () => Promise<void>
}

export const AuthContext = createContext<AuthContextValue>({
  isClerkEnabled: false,
  isSignedIn: false,
  isLoading: false,
  isVerifyingApi: false,
  currentUser: null,
  authError: null,
  refreshCurrentUser: async () => undefined,
})

export function useAuthContext() {
  return useContext(AuthContext)
}
