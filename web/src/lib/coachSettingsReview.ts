import type { CohortExperienceDraft } from '../api'
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

export function toolChanges(item: CoachSettingsReview['tools'][number], activeConfiguration?: CohortExperienceDraft | null): string[] {
  const previous = activeConfiguration ?? item.configuration.published_version?.config
  if (!previous) return [`Tools included: ${item.preview.modules.filter(module => module.enabled).map(module => module.label).join(', ')}.`]
  const changes = []
  for (const module of item.preview.modules) {
    if (module.core) continue
    const enabled = module.id in previous.optional_modules
      ? previous.optional_modules[module.id as keyof typeof previous.optional_modules]
      : module.id !== 'cfo_filter' && module.id !== 'optionality'
    if (module.enabled !== enabled) changes.push(`${module.enabled ? 'Adds' : 'Removes'} ${module.label}.`)
  }
  if (JSON.stringify(previous.module_order ?? []) !== JSON.stringify(item.preview.module_order ?? [])) changes.push('Changes the order of the tools shown below.')
  if ((previous.experience_mode ?? 'household_cfo') !== item.configuration.draft.experience_mode) changes.push(`Changes the experience to ${item.configuration.draft.experience_mode === 'savings_challenge' ? '90-day Savings Challenge' : 'Household CFO'}.`)
  return changes
}
