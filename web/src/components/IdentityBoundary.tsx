import { Fragment, type ReactNode } from 'react'
import { useAuthContext } from '../contexts/authContextValue'
import { matchesAuthIdentity } from '../lib/authIdentity'

export function IdentityBoundary({ children }: { children: ReactNode }) {
  const auth = useAuthContext()
  const identity = auth.isAuthEnabled
    ? !auth.isSignedIn
      ? 'signed-out'
      : auth.isVerifyingApi || !auth.currentUser || !matchesAuthIdentity(auth.currentUser, auth.authProvider === 'workos' ? 'workos' : 'clerk', auth.authIdentityId)
        ? 'signed-in-pending'
        : `${auth.authProvider}:${auth.authIdentityId}:user-${auth.currentUser.id}`
    : auth.currentUser?.id
      ? `${auth.authProvider}:${auth.authIdentityId}:user-${auth.currentUser.id}`
      : 'local-preview'

  return <Fragment key={identity}>{children}</Fragment>
}
