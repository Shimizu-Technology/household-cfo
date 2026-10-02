import type { AdminPersonaDetail } from '../api'

export function savedPreviewDigestForCurrentDraft(persona: AdminPersonaDetail): string | null {
  const savedPreview = persona.preview
  if (!savedPreview || savedPreview.draft_revision !== persona.draft_revision) return null
  return savedPreview.digest
}
