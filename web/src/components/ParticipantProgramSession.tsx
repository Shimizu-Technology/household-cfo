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
  actorId?: number
  participant: boolean
  children: (selection: Selection) => ReactNode
}

// A new authenticated identity owns a new snapshot and discards all private views.
export function ParticipantProgramSession(props: Props) {
  return <ProgramSession key={props.identity} {...props} />
}
function ProgramSession({ authIdentityId, actorId, participant, children }: Props) {
  // Read once for this session. Persisting a verified default or another tab's
  // storage writes must never change the live workspace or discard unsaved drafts.
  const [cohortId, setCohortId] = useState(() => participant ? readParticipantProgram(authIdentityId, actorId) : undefined)
  const [notice, setNotice] = useState<string | null>(null)
  const chooseProgram = useCallback((nextCohortId: number) => {
    if (!participant) return
    setActiveParticipantCohortId(nextCohortId)
    setCohortId(nextCohortId)
    setNotice(null)
  }, [participant])
  const programVerified = useCallback((verifiedCohortId: number) => {
    if (participant) storeParticipantProgram(authIdentityId, actorId, verifiedCohortId)
  }, [participant, authIdentityId, actorId])
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
