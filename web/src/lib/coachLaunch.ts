import { postCoachLaunch, type AdminPersonaDetail, type AdminPersonaReleaseReadiness, type CoachLaunchReview } from '../api'
import type { CoachSettingsReview } from './coachSettingsReview'
import type { GroupReview } from './coachGoLive'

export type PendingCoachLaunch = { key: string; review: CoachLaunchReview }
export function launchStorageKey(userId: number | undefined, personaId: number) { return `hcfo.goLive:${userId ?? 'unknown'}:${personaId}` }
export function readPendingLaunch(key: string): PendingCoachLaunch | null {
  try { const value = JSON.parse(localStorage.getItem(key) ?? 'null'); return value?.key && value?.review ? value : null } catch { return null }
}
export function prepareCoachLaunch(persona: AdminPersonaDetail, readiness: AdminPersonaReleaseReadiness | null, settings: CoachSettingsReview, groups: GroupReview[]): PendingCoachLaunch {
  const configuration = (item: { draft_revision: number; published_version: { id: number } | null; preview?: { digest: string } | null }) => ({ draft_revision: item.draft_revision, published_version_id: item.published_version?.id ?? null, preview_digest: item.preview?.digest ?? '' })
  return { key: crypto.randomUUID(), review: {
    persona: { id: persona.id, ...configuration({ ...persona, draft_revision: persona.draft_revision! }), voice_changes: persona.has_unpublished_changes !== false,
      candidate: readiness?.candidate, evaluation_run: readiness?.evaluation_run, behavioral_preview_evidence: readiness?.behavioral_preview_evidence },
    brand: configuration(settings.brand.configuration),
    tools: settings.tools.map(item => ({ id: item.configuration.cohort.id, ...configuration(item.configuration) })),
    groups: groups.map(item => ({ id: item.group.id, name: item.group.name, roster_digest: item.rosterDigest, participant_ids: item.participantIds, active_release_id: item.activeReleaseId, assignment_persona_id: item.assignmentPersonaId, bundle_digest: item.candidate.bundle_digest })),
  } }
}
export async function finishCoachLaunch(pending: PendingCoachLaunch) { return postCoachLaunch(pending.review, pending.key) }
