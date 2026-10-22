/** Older API deployments still return release-engine terms in readiness guidance. */
export function coachVersionGuidance(message: string) {
  return message
    .replaceAll('Seal a release before launching this cohort.', 'Prepare a version before launching this group.')
    .replaceAll('Activate the cohort\'s current release before planning a runtime rollout.', 'Launch the group’s current version before planning an update.')
    .replace(/Seal a new release before planning a rollout; the latest release is already active\./g, 'Prepare a new version before updating this group; the latest version is already in use.')
    .replace(/Seal a cohort release before planning a rollout\./g, 'Prepare a version before updating this group.')
    .replace(/\bSeal\b/g, 'Prepare')
    .replace(/\bseal\b/g, 'prepare')
    .replace(/\bSealing\b/g, 'Preparing')
    .replace(/\bsealing\b/g, 'preparing')
    .replace(/sealed release/g, 'saved version')
    .replace(/\bsealed\b/g, 'saved')
    .replace(/\bcohort release\b/g, 'version for this group')
    .replace(/\bcohort\b/g, 'group')
    .replace(/participant release runtime/g, 'participant settings')
    .replace(/runtime rollout/g, 'group update')
    .replace(/runtime compatibility/g, 'app compatibility')
    .replace(/participant runtime/g, 'participant settings')
    .replace(/\brollout\b/gi, 'group update')
    .replace(/\b[Rr]elease\b/g, 'version')
    .replace(/\bruntime\b/g, 'participant settings')
    .replace(/\bversion #(\d+)/g, 'version $1')
}
