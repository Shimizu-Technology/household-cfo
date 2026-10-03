import { Fragment, type ReactNode } from 'react'
import { useAuthContext } from '../contexts/authContextValue'

export function IdentityBoundary({ children }: { children: ReactNode }) {
  const auth = useAuthContext()
  const identity = auth.isClerkEnabled
    ? !auth.isSignedIn
      ? 'signed-out'
      : auth.isVerifyingApi || !auth.currentUser || auth.currentUser.clerk_id !== auth.authIdentityId
        ? 'signed-in-pending'
        : `user-${auth.currentUser.id}`
    : auth.currentUser?.id
      ? `user-${auth.currentUser.id}`
      : 'local-preview'

  return <Fragment key={identity}>{children}</Fragment>
}
