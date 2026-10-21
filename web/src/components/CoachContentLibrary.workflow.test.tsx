// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import type { AdminContentPack, AdminPersonaDetail, CurrentUser } from '../api'
import { CoachContentLibrary } from './CoachContentLibrary'
const mocks = vi.hoisted(() => ({ fetchAdminContentItems: vi.fn(), fetchAdminContentPacks: vi.fn(), updateAdminPersonaContentPacks: vi.fn() }))
vi.mock('../api', async (original) => ({ ...await original<typeof import('../api')>(), ...mocks }))
vi.mock('../contexts/authContextValue', () => ({ useAuthContext: () => ({ activeCoachWorkspaceId: 2 }) }))
vi.mock('./CoachContentSources', () => ({ CoachContentSources: () => <section>Private source review task</section> }))
beforeEach(() => { vi.resetAllMocks(); mocks.fetchAdminContentItems.mockResolvedValue([]); mocks.fetchAdminContentPacks.mockResolvedValue([]) })
afterEach(cleanup)
it('keeps source, teaching and collection tasks focused while retaining unsaved drafts', async () => {
  const dirty = vi.fn()
  const lifecycle = { pending: false, begin: vi.fn(() => ({ id: 1, workspaceId: 2 })), isCurrent: vi.fn(() => true), finish: vi.fn() }
  render(<CoachContentLibrary currentUser={{ id: 10, is_admin: false } as CurrentUser} selectedPersona={null} mutationLifecycle={lifecycle} onDirtyChange={dirty} onPersonaChange={() => undefined} />)
  expect(screen.getByText('Private source review task').closest('[hidden]')).toBeTruthy()
  await waitFor(() => expect(screen.getByRole('button', { name: 'Teaching items' })).toHaveProperty('disabled', false))
  fireEvent.click(screen.getByRole('button', { name: 'Teaching items' }))
  fireEvent.click(screen.getByRole('button', { name: 'New item' }))
  fireEvent.change(screen.getByLabelText('Title'), { target: { value: 'Unfinished coach guidance' } })
  fireEvent.click(screen.getByRole('button', { name: 'Collections' }))
  expect(screen.getByLabelText('Title').closest('[hidden]')).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: 'New collection' }))
  fireEvent.change(screen.getByLabelText('Collection name'), { target: { value: 'Unfinished collection' } })
  fireEvent.click(screen.getByRole('button', { name: 'Teaching items' }))
  expect(screen.getByLabelText('Title')).toHaveProperty('value', 'Unfinished coach guidance')
  expect(dirty).toHaveBeenLastCalledWith(true)
})

const publishedCollection = {
  id: 40, name: 'Coach method', description: '', scope: 'coach', pack_kind: 'coaching_method', draft_revision: 1,
  draft_manifest_digest: 'draft', archived: false, editable: true, publishable: true, draft_items: [],
  current_published_version: { id: 55, pack_id: 40, name: 'Coach method', description: '', scope: 'coach', pack_kind: 'coaching_method', version: 2, digest: 'v2', published_at: '', items: [] },
  versions: [], has_unpublished_changes: false, item_updates_available: false, update_available: false, updated_at: '',
} as AdminContentPack
const mia = { id: 5, name: 'Mia', status: 'published', draft_revision: 4, permissions: { edit: true }, content_packs: [{ id: 51, pack_id: 40 }, { id: 52, pack_id: 41 }] } as AdminPersonaDetail
const lifecycle = { pending: false, begin: () => ({ id: 1, workspaceId: 2 }), isCurrent: () => true, finish: () => undefined }

it('attaches the selected collection version without dropping other teaching or losing selection', async () => {
  mocks.fetchAdminContentPacks.mockResolvedValue([publishedCollection])
  const saved = { ...mia, draft_revision: 5, content_packs: [publishedCollection.current_published_version!, mia.content_packs![1]] }
  mocks.updateAdminPersonaContentPacks.mockResolvedValue(saved)
  const onPersonaChange = vi.fn()
  render(<CoachContentLibrary currentUser={{ id: 10, is_admin: false } as CurrentUser} selectedPersona={mia} mutationLifecycle={lifecycle} onPersonaChange={onPersonaChange} />)
  await waitFor(() => expect(screen.getByRole('button', { name: 'Collections' })).toHaveProperty('disabled', false))
  fireEvent.click(screen.getByRole('button', { name: 'Collections' }))
  fireEvent.click(screen.getByRole('button', { name: /Coach method/ }))
  fireEvent.click(screen.getByRole('button', { name: 'Use with Mia' }))
  await waitFor(() => expect(mocks.updateAdminPersonaContentPacks).toHaveBeenCalledWith(5, 4, [52, 55]))
  expect(onPersonaChange).toHaveBeenCalledWith(saved)
  await screen.findByText(/Collection saved to Mia/)
  expect(screen.getByLabelText('Collection name')).toHaveProperty('value', 'Coach method')
  expect(screen.getByRole('button', { name: 'Collections' }).getAttribute('aria-pressed')).toBe('true')
})

it('keeps collection selection and offers retry when attachment fails', async () => {
  mocks.fetchAdminContentPacks.mockResolvedValue([publishedCollection])
  mocks.updateAdminPersonaContentPacks.mockRejectedValueOnce(new Error('Try again shortly.')).mockResolvedValue(mia)
  render(<CoachContentLibrary currentUser={{ id: 10, is_admin: false } as CurrentUser} selectedPersona={mia} mutationLifecycle={lifecycle} onPersonaChange={() => undefined} />)
  await waitFor(() => expect(screen.getByRole('button', { name: 'Collections' })).toHaveProperty('disabled', false))
  fireEvent.click(screen.getByRole('button', { name: 'Collections' }))
  fireEvent.click(screen.getByRole('button', { name: /Coach method/ }))
  fireEvent.click(screen.getByRole('button', { name: 'Use with Mia' }))
  await screen.findByRole('alert')
  expect(screen.getByLabelText('Collection name')).toHaveProperty('value', 'Coach method')
  await waitFor(() => expect(screen.getByRole('button', { name: 'Use with Mia' })).toHaveProperty('disabled', false))
  fireEvent.click(screen.getByRole('button', { name: 'Use with Mia' }))
  await screen.findByText(/Collection saved to Mia/)
  expect(mocks.updateAdminPersonaContentPacks).toHaveBeenCalledTimes(2)
})

it('explains why a viewer cannot attach a collection', async () => {
  mocks.fetchAdminContentPacks.mockResolvedValue([publishedCollection])
  render(<CoachContentLibrary currentUser={{ id: 10, is_admin: false, coach_workspaces: [{ id: 2, membership_role: 'viewer' }] } as CurrentUser} selectedPersona={{ ...mia, permissions: { ...mia.permissions, edit: false } }} mutationLifecycle={lifecycle} onPersonaChange={() => undefined} />)
  await waitFor(() => expect(screen.getByRole('button', { name: 'Collections' })).toHaveProperty('disabled', false))
  expect(screen.getByRole('button', { name: 'New item' })).toHaveProperty('disabled', true)
  fireEvent.click(screen.getByRole('button', { name: 'Collections' }))
  expect(screen.getByRole('button', { name: 'New collection' })).toHaveProperty('disabled', true)
  fireEvent.click(screen.getByRole('button', { name: /Coach method/ }))
  expect(screen.getByText(/read-only for your role/)).toBeTruthy()
  expect(screen.getByRole('button', { name: 'Use with Mia' })).toHaveProperty('disabled', true)
  expect(mocks.updateAdminPersonaContentPacks).not.toHaveBeenCalled()
})
