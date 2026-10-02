// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { AdminPersonaDetail, PersonaConfiguration } from '../api'
import { PhraseEditor } from './CoachStudio'

const reviewedPhrase = {
  artifact_id: 'approved-source-31',
  provenance: 'approved_source' as const,
  text: 'One step at a time',
  meaning: 'Choose one practical action.',
  allowed_contexts: ['general'] as const,
  prohibited_contexts: ['crisis'] as const,
  frequency: 'rare' as const,
  caution: 'Avoid during urgent safety needs.',
}

const access: AdminPersonaDetail['phrase_artifact_access'] = {
  can_add: true,
  artifacts: [{
    artifact_id: 'approved-source-31', provenance: 'approved_source', source_role_at_capture: null,
    source_label: 'Approved private source', can_edit: false, can_remove: true, can_move: true,
    locked: true, locked_reason: 'Exact wording is locked to its approved source review.',
  }],
}

const promotions: NonNullable<AdminPersonaDetail['approved_phrase_promotions']> = [{
  id: 8, artifact_id: 'approved-source-31', phrase: {
    text: reviewedPhrase.text, meaning: reviewedPhrase.meaning, allowed_contexts: ['general'], prohibited_contexts: ['crisis'], frequency: 'rare', caution: reviewedPhrase.caution,
  }, source_label: 'Approved private source', active: true, can_restore: false, promoted_at: '2026-10-02T00:00:00Z',
}, {
  id: 9, artifact_id: 'approved-source-32', phrase: {
    text: 'Plan for the rainy day', meaning: 'Keep a small buffer.', allowed_contexts: ['routine'], prohibited_contexts: ['crisis'], frequency: 'very_rare', caution: '',
  }, source_label: 'Approved private source', active: false, can_restore: true, promoted_at: '2026-10-01T00:00:00Z',
}]

describe('approved source phrases in the manual persona editor', () => {
  afterEach(cleanup)

  it('keeps exact fields locked while preserving move/remove controls and restore history', async () => {
    const mutate = vi.fn()
    const onRestore = vi.fn()
    render(<PhraseEditor
      draft={{ phrases: [reviewedPhrase] } as unknown as PersonaConfiguration}
      mutate={mutate}
      access={access}
      promotions={promotions}
      restorePending={false}
      restoreDisabled={false}
      onRestore={onRestore}
    />)

    expect(screen.getByText('Approved private source')).toBeTruthy()
    expect(screen.getAllByText(/Approved private source · Promoted/i)).toHaveLength(2)
    expect((screen.getByLabelText('Phrase') as HTMLInputElement).disabled).toBe(true)
    expect(screen.getByRole('button', { name: 'Remove phrase 1' })).toBeTruthy()
    expect(screen.getByText('Removed reviewed phrases')).toBeTruthy()
    await userEvent.click(screen.getByRole('button', { name: 'Restore reviewed phrase' }))
    expect(onRestore).toHaveBeenCalledWith(9)
  })

  it('blocks restore while other assistant edits are unsaved', () => {
    render(<PhraseEditor
      draft={{ phrases: [reviewedPhrase] } as unknown as PersonaConfiguration}
      mutate={() => undefined}
      access={access}
      promotions={promotions}
      restorePending={false}
      restoreDisabled
      onRestore={() => undefined}
    />)
    expect((screen.getByRole('button', { name: 'Restore reviewed phrase' }) as HTMLButtonElement).disabled).toBe(true)
    expect(screen.getByText(/Save or discard other assistant edits/i)).toBeTruthy()
  })
})
