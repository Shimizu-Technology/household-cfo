import type { ParticipantPrograms } from '../participantProgramsApi'
// Only a program ID is stored. Every restored choice must still pass server authorization.
const PREFIX = 'household-cfo:participant-program:v1:'
function key(identity: string, actorId: number) { return `${PREFIX}${encodeURIComponent(identity)}:${actorId}` }
export function readParticipantProgram(identity: string | null | undefined, actorId: number | undefined): number | undefined {
  if (!identity || !actorId) return undefined
  try {
    const value = window.localStorage.getItem(key(identity, actorId))
    if (!value) return undefined
    const id = Number(value)
    if (Number.isSafeInteger(id) && id > 0 && String(id) === value) return id
    window.localStorage.removeItem(key(identity, actorId))
  } catch { /* Storage may be unavailable; the server's default still works. */ }
  return undefined
}
export function storeParticipantProgram(identity: string | null | undefined, actorId: number | undefined, cohortId: number | undefined) {
  if (!identity || !actorId) return
  try {
    if (cohortId !== undefined && Number.isSafeInteger(cohortId) && cohortId > 0) window.localStorage.setItem(key(identity, actorId), String(cohortId))
    else window.localStorage.removeItem(key(identity, actorId))
  } catch { /* Choosing a program remains available without local storage. */ }
}

// Metadata is authoritative for membership. A paused tool or network error is not a revoked program.
export function verifiedParticipantProgram(programs: ParticipantPrograms, actorId: number, cohortId: number): boolean {
  if (programs.actor_id !== actorId) throw new Error('Program choices belong to a different account. Refresh your session.')
  if (programs.selection_unavailable) return false
  if (programs.current_cohort_id !== cohortId || programs.current_program?.id !== cohortId) throw new Error('The selected program could not be verified. Refresh your program choices.')
  return true
}
