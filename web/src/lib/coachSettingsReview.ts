import { fetchWorkspaceBrand, previewWorkspaceBrand, fetchCohortExperienceConfiguration, previewCohortExperienceConfiguration, type WorkspaceBrandConfiguration, type WorkspaceBrandPreview, type CohortExperienceConfiguration, type CohortExperiencePreview } from '../api'

export type CoachSettingsReview = {
  brand: { configuration: WorkspaceBrandConfiguration; preview: WorkspaceBrandPreview }
  tools: Array<{ configuration: CohortExperienceConfiguration; preview: CohortExperiencePreview }>
}

export async function reviewCoachSettings(groupIds: number[], isCurrent: () => boolean): Promise<CoachSettingsReview> {
  const guard = () => { if (!isCurrent()) throw new Error('Your program changed. Reopen Go live before continuing.') }
  guard()
  const brand = await fetchWorkspaceBrand()
  guard()
  if (!brand.permissions.preview || !brand.permissions.publish) throw new Error('Ask a program owner or reviewer to approve the appearance.')
  const brandPreview = await previewWorkspaceBrand(brand.draft_revision)
  guard()
  const tools = []
  for (const id of groupIds) {
    const configuration = await fetchCohortExperienceConfiguration(id)
    guard()
    if (!configuration.permissions.review || !configuration.permissions.publish) throw new Error(`Ask a program owner or reviewer to approve the tools for ${configuration.cohort.name}.`)
    const result = await previewCohortExperienceConfiguration(id, configuration.draft_revision, true)
    guard()
    tools.push({ configuration: result.experience_configuration, preview: result.preview })
  }
  return { brand: { configuration: brandPreview.brand_configuration, preview: brandPreview.preview }, tools }
}
