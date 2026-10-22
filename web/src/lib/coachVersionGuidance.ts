/** Older API deployments still return release-engine terms in readiness guidance. */
export function coachVersionGuidance(message: string) {
  return message
    .replaceAll('Activate the cohort\'s current release before planning a runtime rollout.', 'Launch the group’s current version before planning an update.')
    .replace(/sealed release/g, 'saved version')
    .replace(/participant release runtime/g, 'participant settings')
    .replace(/runtime rollout/g, 'group update')
    .replace(/runtime compatibility/g, 'app compatibility')
    .replace(/participant runtime/g, 'participant settings')
    .replace(/\bruntime\b/g, 'participant settings')
    .replace(/\b[Rr]elease #(\d+)/g, 'version $1')
}
