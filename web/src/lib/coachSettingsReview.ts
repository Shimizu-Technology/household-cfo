import { fetchWorkspaceBrand, previewWorkspaceBrand, publishWorkspaceBrand, fetchCohortExperienceConfiguration, previewCohortExperienceConfiguration, publishCohortExperienceConfiguration, type WorkspaceBrandConfiguration, type WorkspaceBrandPreview, type CohortExperienceConfiguration, type CohortExperiencePreview } from '../api'

export type CoachSettingsReview = {
  brand: { configuration: WorkspaceBrandConfiguration; preview: WorkspaceBrandPreview }
  tools: Array<{ configuration: CohortExperienceConfiguration; preview: CohortExperiencePreview }>
}
export type PublishedCoachSettings = { brandVersionId: number; toolVersionIds: Record<number, number> }

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
    const result = await previewCohortExperienceConfiguration(id, configuration.draft_revision)
    guard()
    tools.push({ configuration: result.experience_configuration, preview: result.preview })
  }
  return { brand: { configuration: brandPreview.brand_configuration, preview: brandPreview.preview }, tools }
}

/** Publish only the exact saved settings shown in the review, using existing authority/concurrency gates. */
export async function publishCoachSettings(review: CoachSettingsReview, requestId: string, isCurrent: () => boolean): Promise<PublishedCoachSettings> {
  const guard = () => { if (!isCurrent()) throw new Error('Your program changed. Reopen Go live before continuing.') }
  const assertSame = (before: WorkspaceBrandConfiguration | CohortExperienceConfiguration, after: WorkspaceBrandConfiguration | CohortExperienceConfiguration) => {
    if (before.draft_revision !== after.draft_revision || before.published_version?.id !== after.published_version?.id || before.preview?.digest !== after.preview?.digest) throw new Error('Your appearance or tools changed. Review the latest settings before going live.')
  }
  guard()
  assertSame(review.brand.configuration, await fetchWorkspaceBrand())
  guard()
  for (const item of review.tools) {
    assertSame(item.configuration, await fetchCohortExperienceConfiguration(item.configuration.cohort.id))
    guard()
  }
  const brand = review.brand.configuration
  let brandVersion = brand.published_version
  if (brand.has_unpublished_changes !== false) {
    brandVersion = (await publishWorkspaceBrand({ draft_revision: brand.draft_revision, preview_digest: review.brand.preview.digest, expected_published_version_id: brandVersion?.id ?? null }, `${requestId}:appearance`)).published_version
    guard()
  }
  if (!brandVersion) throw new Error('The program appearance could not be published.')
  const toolVersionIds: Record<number, number> = {}
  for (const item of review.tools) {
    const configuration = item.configuration
    let version = configuration.published_version
    if (configuration.has_unpublished_changes !== false) {
      version = (await publishCohortExperienceConfiguration(configuration.cohort.id, { draft_revision: configuration.draft_revision, preview_digest: item.preview.digest, expected_published_version_id: version?.id ?? null })).published_version
      guard()
    }
    if (!version) throw new Error(`The tools for ${configuration.cohort.name} could not be published.`)
    toolVersionIds[configuration.cohort.id] = version.id
  }
  return { brandVersionId: brandVersion.id, toolVersionIds }
}
