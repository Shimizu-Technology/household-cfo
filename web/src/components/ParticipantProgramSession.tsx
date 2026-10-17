import { useCallback, useState, type ReactNode } from 'react'
import { setActiveParticipantCohortId } from '../api'
import { readParticipantProgram, storeParticipantProgram } from '../lib/participantProgramSelection'

type Selection = {
  selectedCohortId?: number
  selectionNotice: string | null
  onChooseProgram: (cohortId: number) => void
  onProgramVerified: (cohortId: number) => void
  onProgramUnavailable: () => void
}
type Props = {
  identity: string
  authIdentityId: string | null
  legacyAuthIdentityId?: string | null
  actorId?: number
  participant: boolean
  children: (selection: Selection) => ReactNode
}

// A new authenticated identity owns a new snapshot and discards all private views.
export function ParticipantProgramSession(props: Props) {
  return <ProgramSession key={props.identity} {...props} />
}
function ProgramSession({ authIdentityId, legacyAuthIdentityId, actorId, participant, children }: Props) {
  // Read once for this session. Persisting a verified default or another tab's
  // storage writes must never change the live workspace or discard unsaved drafts.
  const [cohortId, setCohortId] = useState(() => participant ? readParticipantProgram(authIdentityId, actorId) ?? readParticipantProgram(legacyAuthIdentityId, actorId) : undefined)
  const [notice, setNotice] = useState<string | null>(null)
  const chooseProgram = useCallback((nextCohortId: number) => {
    if (!participant) return
    setActiveParticipantCohortId(nextCohortId)
    storeParticipantProgram(authIdentityId, actorId, nextCohortId)
    setCohortId(nextCohortId)
    setNotice(null)
  }, [participant, authIdentityId, actorId])
  const programVerified = useCallback((verifiedCohortId: number) => {
    // Only a program the participant chose (or restored from their own earlier choice, including a
    // migrated identity) is persisted. A server-picked default is never stored: it would pin the
    // participant to it and defeat the server's default rule (e.g. a challenge joined later).
    if (participant && verifiedCohortId === cohortId) storeParticipantProgram(authIdentityId, actorId, verifiedCohortId)
  }, [participant, authIdentityId, actorId, cohortId])
  const programUnavailable = useCallback(() => {
    if (!participant) return
    storeParticipantProgram(authIdentityId, actorId, undefined)
    setActiveParticipantCohortId(null)
    setCohortId(undefined)
    setNotice('Your previous program is no longer available. Your current authorized program is shown below; use Program to check your choices.')
  }, [participant, authIdentityId, actorId])
  return children({
    selectedCohortId: participant ? cohortId : undefined,
    selectionNotice: notice,
    onChooseProgram: chooseProgram,
    onProgramVerified: programVerified,
    onProgramUnavailable: programUnavailable,
  })
}
