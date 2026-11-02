import { useAuthContext } from '../contexts/authContextValue'
import { useState, type ReactNode } from 'react'
import { RetentionContext } from './documentUploadRetentionState'

// Lives above the authenticated workspace so access verification can remount it.
// The boundary keys it by the signed-in subject; a financial restart clears it.
export function DocumentUploadRetention({ children }: { children: ReactNode }) {
  const [files, setFiles] = useState<Record<string, File | null>>({})
  return <RetentionContext.Provider value={{ files, clear: () => setFiles({}), retain: (slot, file, completedFile) => {
    setFiles(current => completedFile && current[slot] !== completedFile ? current : { ...current, [slot]: file })
  } }}>{children}</RetentionContext.Provider>
}

export function DocumentUploadRetentionBoundary({ children }: { children: ReactNode }) {
  const auth = useAuthContext()
  const identity = auth.authIdentityId ? `${auth.authProvider}:${auth.authIdentityId}` : null
  const [lastIdentity, setLastIdentity] = useState(identity)
  if (identity && identity !== lastIdentity) setLastIdentity(identity)
  // A 401 clears the session subject while its sign-in dialog is open. Keep
  // private files behind IdentityBoundary until the same subject is verified.
  const recovering = auth.authRecoveryRequired || auth.isLoading || auth.isVerifyingApi
  const scope = identity ?? (recovering ? lastIdentity : null)
  return <DocumentUploadRetention key={scope ?? 'signed-out'}>{children}</DocumentUploadRetention>
}

