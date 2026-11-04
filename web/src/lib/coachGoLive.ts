import { advanceCohortRollout, fetchAdminCohortPersonaAssignment, fetchCohortInitialLaunch, fetchCohortReleaseStudio, fetchCohortRolloutStudio, launchCohortRelease, planCohortRollout, sealCohortRelease, updateAdminCohortPersonaAssignment, type AdminPersonaAssignableCohort, type CohortReleaseCandidate } from '../api'

import type { PublishedCoachSettings } from './coachSettingsReview'

export type GroupReview = { group: AdminPersonaAssignableCohort; candidate: CohortReleaseCandidate; participantIds: number[]; rosterDigest: string; activeReleaseId: number | null; assignmentPersonaId: number | null }

/** Freeze the settings and people the coach actually reviews before the one Go live action. */
export async function reviewCoachGroup(group: AdminPersonaAssignableCohort): Promise<GroupReview> {
  const [releases, rollout, assignment] = await Promise.all([fetchCohortReleaseStudio(group.id), fetchCohortRolloutStudio(group.id), fetchAdminCohortPersonaAssignment(group.id)])
  if (!releases.candidate || !releases.permissions.seal || !rollout.permissions.manage || rollout.open_rollout) throw new Error(`Finish the existing group update or ask a program owner to publish ${group.name}.`)
  if (rollout.active_release && rollout.current_roster.participants.length === 0) throw new Error(`Add a participant to ${group.name} in People before updating its live tools.`)
  return { group, candidate: releases.candidate, participantIds: rollout.current_roster.participants.map((item) => item.user_id), rosterDigest: rollout.current_roster.digest, activeReleaseId: rollout.active_release?.id ?? null, assignmentPersonaId: assignment?.persona.id ?? null }
}

/** Existing version, launch and rollout endpoints retain their concurrency, privacy and audit gates. */
export async function publishCoachGroup(review: GroupReview, personaId: number, personaVersionId: number, requestId: string, isCurrent: () => boolean, settings?: PublishedCoachSettings) {
  const guard = () => { if (!isCurrent()) throw new Error('Your program changed. Reopen Go live before continuing.') }
  const id = review.group.id
  guard()
  const [assignment, current, roster] = await Promise.all([fetchAdminCohortPersonaAssignment(id), fetchCohortReleaseStudio(id), fetchCohortRolloutStudio(id)])
  guard()
  const reviewed = review.candidate
  const next = current.candidate
  const sameComponents = (candidate: CohortReleaseCandidate) =>
    (settings ? candidate.brand_version_id === settings.brandVersionId : candidate.brand_snapshot_digest === reviewed.brand_snapshot_digest) &&
    candidate.experience_version_id === (settings?.toolVersionIds[id] ?? reviewed.experience_version_id) &&
    // A newly published tools schema may legitimately change its catalog.
    (settings && settings.toolVersionIds[id] !== reviewed.experience_version_id || candidate.registry_digest === reviewed.registry_digest)
  if (!next || !sameComponents(next) || roster.current_roster.digest !== review.rosterDigest || (roster.active_release?.id ?? null) !== review.activeReleaseId || roster.open_rollout || (assignment?.persona.id ?? null) !== review.assignmentPersonaId) {
    throw new Error(`${review.group.name} changed. Review its latest settings and people before going live.`)
  }
  if (assignment?.persona.id !== personaId) {
    await updateAdminCohortPersonaAssignment(id, personaId, assignment?.persona.id ?? null)
    guard()
  }
  const prepared = await fetchCohortReleaseStudio(id)
  guard()
  const candidate = prepared.candidate
  if (!candidate?.ready || !sameComponents(candidate) || candidate.registry_digest !== next.registry_digest || candidate.registry_version !== next.registry_version || candidate.persona_version_id !== personaVersionId) throw new Error(`${review.group.name} is not ready. Check its assistant, appearance and tools in Advanced / history.`)
  let releaseId = candidate.expected_latest_release_id
  if (candidate.seal_needed) {
    const sealed = await sealCohortRelease(id, {
      expected_bundle_digest: candidate.bundle_digest, expected_assignment_id: candidate.assignment_id,
      expected_persona_version_id: candidate.persona_version_id, expected_experience_version_id: candidate.experience_version_id,
      expected_brand_version_id: candidate.brand_version_id, expected_tool_registry_digest: candidate.registry_digest,
      expected_tool_registry_version: candidate.registry_version, expected_latest_release_id: candidate.expected_latest_release_id,
    }, `${requestId}:seal:${id}`)
    guard()
    releaseId = sealed.release.id
  }
  if (!releaseId) throw new Error(`${review.group.name} needs a saved version before going live.`)
  const launch = await fetchCohortInitialLaunch(id)
  guard()
  if (!launch.active_release_id) {
    if (!launch.can_launch || launch.release?.id !== releaseId || launch.roster_digest !== review.rosterDigest) throw new Error(`${review.group.name} is prepared but could not go live. Review the group in Advanced / history.`)
    await launchCohortRelease(id, { release_id: releaseId, preview_digest: launch.preview_digest, expected_roster_digest: review.rosterDigest }, `${requestId}:launch:${id}`)
    guard()
    return
  }
  const rollout = await fetchCohortRolloutStudio(id)
  guard()
  if (rollout.active_release?.id === releaseId) return
  if (rollout.latest_release?.id !== releaseId || !rollout.permissions.plan || rollout.current_roster.digest !== review.rosterDigest || (rollout.active_release?.id ?? null) !== review.activeReleaseId) throw new Error(`${review.group.name} needs a fresh group review.`)
  let result = await planCohortRollout(id, { target_release_id: releaseId, expected_latest_release_id: releaseId, expected_roster_digest: review.rosterDigest, waves: [{ name: 'Everyone reviewed', user_ids: review.participantIds }] }, `${requestId}:plan:${id}`)
  guard()
  // One reviewed group, followed by completion. Never bypass participant readiness or an existing plan.
  for (let step = 0; step < 2 && result.rollout.status !== 'completed'; step += 1) {
    if (!result.rollout.permissions.advance || result.rollout.latest_transition_id === null) throw new Error(`${review.group.name} is waiting for participant readiness. Continue its saved update in Advanced / history.`)
    result = await advanceCohortRollout(id, result.rollout.id, { expected_status: result.rollout.status, expected_current_wave_position: result.rollout.current_wave_position, expected_latest_transition_id: result.rollout.latest_transition_id, readiness_digest: result.rollout.next_wave_readiness_digest }, `${requestId}:advance:${id}:${step}`)
    guard()
  }
  if (result.rollout.status !== 'completed') throw new Error(`${review.group.name} has a saved update to finish in Advanced / history.`)
}
