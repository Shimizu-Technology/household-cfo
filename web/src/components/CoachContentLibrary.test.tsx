// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { AdminContentItem, AdminContentItemVersion, AdminContentPack, CurrentUser } from '../api'
import { ContentItemsPanel, ContentPacksPanel } from './CoachContentLibrary'

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
    expect(screen.getByText('Legacy phrase selections must be removed')).toBeTruthy()
    expect(screen.getByText(/direct assistant promotion/i)).toBeTruthy()
    expect((screen.getByRole('button', { name: 'Remove legacy phrases to save' }) as HTMLButtonElement).disabled).toBe(true)
    expect((screen.getByRole('button', { name: 'Remove and save legacy phrases first' }) as HTMLButtonElement).disabled).toBe(true)

    await userEvent.click(screen.getByRole('button', { name: 'Remove legacy phrase' }))
    expect(screen.getByText(/Save the pack to confirm removal before publishing/i)).toBeTruthy()
    expect((screen.getByRole('button', { name: 'Remove and save legacy phrases first' }) as HTMLButtonElement).disabled).toBe(true)
    await userEvent.click(screen.getByRole('button', { name: 'Save pack' }))
    await waitFor(() => expect(onSave).toHaveBeenCalledWith(pack, expect.objectContaining({ item_version_ids: [11] })))
  })

  it('does not offer phrase as a type for manually created content', async () => {
    render(<ContentItemsPanel
      currentUser={{ id: 2, is_admin: false } as CurrentUser}
      platformMode={false}
      items={[]}
      selected={null}
      reviewRequest={0}
      focusRequest={0}
      busy={false}
      onDirtyChange={() => undefined}
      onSelect={() => undefined}
      onCreate={async () => true}
      onSave={async () => true}
      onApprove={async () => true}
    />)

    await userEvent.click(screen.getByRole('button', { name: 'New item' }))
    const typeSelect = screen.getByLabelText('Type') as HTMLSelectElement
    expect(typeSelect.querySelector('option[value="phrase"]')).toBeNull()
    expect(screen.queryByText(/^Phrase$/)).toBeNull()
  })

  it('keeps legacy phrase items visible but read-only', async () => {
    const legacyItem = item(2, 'Island phrase', 'phrase', legacyPhrase)
    render(<ContentItemsPanel
      currentUser={{ id: 2, is_admin: false } as CurrentUser}
      platformMode={false}
      items={[legacyItem]}
      selected={legacyItem}
      reviewRequest={0}
      focusRequest={0}
      busy={false}
      onDirtyChange={() => undefined}
      onSelect={() => undefined}
      onCreate={async () => true}
      onSave={async () => true}
      onApprove={async () => true}
    />)

    expect((screen.getByLabelText('Title') as HTMLInputElement).disabled).toBe(true)
    expect((screen.getByLabelText('Type') as HTMLSelectElement).disabled).toBe(true)
    expect(screen.getByText(/Legacy phrase items are read-only/i)).toBeTruthy()
    expect(screen.queryByRole('button', { name: 'Save draft' })).toBeNull()
  })
})
