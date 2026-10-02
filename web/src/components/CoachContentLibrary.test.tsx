// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { AdminContentItem, AdminContentItemVersion, AdminContentPack, CurrentUser } from '../api'
import { ContentPacksPanel } from './CoachContentLibrary'

const approvedAt = '2026-10-02T00:00:00Z'
function version(id: number, itemId: number, title: string, kind: AdminContentItemVersion['kind']): AdminContentItemVersion {
  return { id, item_id: itemId, title, kind, content: `${title} content`, always_on: false, version: 1, digest: `digest-${id}`, approved_at: approvedAt }
}
function item(id: number, title: string, kind: AdminContentItem['kind'], current: AdminContentItemVersion): AdminContentItem {
  return { id, title, scope: 'coach', kind, always_on: false, draft_content: current.content, draft_revision: 1, draft_digest: current.digest, archived: false, editable: true, approvable: true, current_approved_version: current, versions: [current], has_unapproved_changes: false, updated_at: approvedAt }
}

const guidance = version(11, 1, 'Decision guide', 'guidance')
const legacyPhrase = version(22, 2, 'Island phrase', 'phrase')
const pack: AdminContentPack = {
  id: 4, name: 'Coach basics', description: '', scope: 'coach', pack_kind: 'voice_culture', draft_revision: 2,
  draft_manifest_digest: 'pack-digest', archived: false, editable: true, publishable: true,
  draft_items: [guidance, legacyPhrase], current_published_version: null, versions: [], has_unpublished_changes: true,
  item_updates_available: false, update_available: false, updated_at: approvedAt,
}

describe('ContentPacksPanel phrase migration', () => {
  afterEach(cleanup)

  it('excludes new phrase choices while preserving an explicit removal path for legacy selections', async () => {
    const onSave = vi.fn().mockResolvedValue(true)
    const panelProps = {
      currentUser: { id: 2, is_admin: false } as CurrentUser,
      platformMode: false,
      packs: [pack],
      items: [item(1, 'Decision guide', 'guidance', guidance), item(2, 'Island phrase', 'phrase', legacyPhrase)],
      busy: false,
      onDirtyChange: () => undefined,
      onSelect: () => undefined,
      onCreate: async () => true,
      onSave,
      onPublish: async () => true,
    }
    const view = render(<ContentPacksPanel {...panelProps} selected={null} />)
    await userEvent.click(screen.getByRole('button', { name: /Coach basics/i }))
    view.rerender(<ContentPacksPanel {...panelProps} selected={pack} />)

    expect(screen.getByRole('checkbox', { name: /Decision guide/i })).toBeTruthy()
    expect(screen.queryByRole('checkbox', { name: /Island phrase/i })).toBeNull()
    expect(screen.getByText('Legacy phrase selections')).toBeTruthy()
    expect(screen.getByText(/direct assistant promotion/i)).toBeTruthy()

    await userEvent.click(screen.getByRole('button', { name: 'Remove legacy phrase' }))
    await userEvent.click(screen.getByRole('button', { name: 'Save pack' }))
    await waitFor(() => expect(onSave).toHaveBeenCalledWith(pack, expect.objectContaining({ item_version_ids: [11] })))
  })
})
