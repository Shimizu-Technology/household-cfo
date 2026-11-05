import { fetchAdminCohortPersonaAssignment, fetchCohortReleaseStudio, fetchCohortRolloutStudio, type AdminPersonaAssignableCohort, type CohortReleaseCandidate } from '../api'

export type GroupReview = { group: AdminPersonaAssignableCohort; candidate: CohortReleaseCandidate; participantIds: number[]; rosterDigest: string; activeReleaseId: number | null; assignmentPersonaId: number | null }

/** Freeze the settings and people the coach actually reviews before the one Go live action. */
export async function reviewCoachGroup(group: AdminPersonaAssignableCohort): Promise<GroupReview> {
  const [releases, rollout, assignment] = await Promise.all([fetchCohortReleaseStudio(group.id), fetchCohortRolloutStudio(group.id), fetchAdminCohortPersonaAssignment(group.id)])
  if (!releases.candidate || !releases.permissions.seal || !rollout.permissions.manage || rollout.open_rollout) throw new Error(`Finish the existing group update or ask a program owner to publish ${group.name}.`)
  const conflicts = releases.readiness?.blockers?.filter(message => message.includes('Participant access')) ?? []
  const unready = rollout.current_roster.participants.filter(person => person.readiness === 'needs_account' || person.readiness === 'removed')
  if (conflicts.length) throw new Error(conflicts.join(' '))
  if (unready.length) throw new Error(unready.map(person => `${person.full_name} needs to finish setting up their sign-in or have their group access reviewed in Participant access before this update can go live.`).join(' '))
  if (rollout.active_release && rollout.current_roster.participants.length === 0) throw new Error(`Add a participant to ${group.name} in People before updating its live tools.`)
  return { group, candidate: releases.candidate, participantIds: rollout.current_roster.participants.map((item) => item.user_id), rosterDigest: rollout.current_roster.digest, activeReleaseId: rollout.active_release?.id ?? null, assignmentPersonaId: assignment?.persona.id ?? null }
}
