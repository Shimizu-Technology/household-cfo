// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as api from '../api'
import { NEUTRAL_BRAND } from '../contexts/brandContextValue'
import { CoachProgramSettings, CreateCoachProgram } from './CoachProgramSettings'
import type { CurrentUser, WorkspaceBrandConfiguration, CoachWorkspaceSettings } from '../api'

vi.mock('../api', async (importOriginal) => ({
  ...await importOriginal<typeof import('../api')>(),
  fetchCoachWorkspaceSettings: vi.fn(), fetchWorkspaceBrand: vi.fn(),
  updateCoachWorkspaceSettings: vi.fn(), saveWorkspaceBrand: vi.fn(),
  previewWorkspaceBrand: vi.fn(), publishWorkspaceBrand: vi.fn(),
  restoreWorkspaceBrandVersion: vi.fn(), createCoachWorkspace: vi.fn(),
}))
const workspace: CoachWorkspaceSettings = { id: 1, name: 'Island program', slug: 'island', membership_role: 'owner', coach_profile: { display_name: 'Mrs. Mel', title: 'Financial coach', bio: '' }, revision: 0, permissions: { manage: true } }
const actor = { is_admin: false, full_name: 'Mrs. Mel' } as CurrentUser
const draft = { ...NEUTRAL_BRAND, product_name: 'Island Money', short_name: 'Island', organization_name: 'Mel', welcome_heading: 'Welcome', welcome_description: 'One step at a time.' }
const configuration: WorkspaceBrandConfiguration = { workspace: { id: 1, name: workspace.name, slug: workspace.slug }, draft, draft_revision: 1, preview_required: true, preview: null, published_version: { id: 1, number: 1, digest: 'initial', published_at: '2026-10-01T00:00:00Z', published_by: { id: 1, full_name: 'Mrs. Mel' } }, versions: [], permissions: { edit: true, preview: true, publish: true, rollback: true } }
const lifecycle = { pending: false, begin: vi.fn(() => ({ id: 1, workspaceId: 1 })), isCurrent: vi.fn(() => true), finish: vi.fn() }
function renderSettings() { render(<CoachProgramSettings workspaceId={1} currentUser={actor} mutationLifecycle={lifecycle} onDirtyChange={vi.fn()} />) }

describe('program settings', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(api.fetchCoachWorkspaceSettings).mockResolvedValue(workspace)
    vi.mocked(api.fetchWorkspaceBrand).mockResolvedValue(configuration)
    vi.spyOn(window, 'confirm').mockReturnValue(true)
  })
  afterEach(() => { cleanup(); vi.restoreAllMocks() })

  it('requires the exact saved preview before publication and explains release pinning', async () => {
    const user = userEvent.setup()
    const saved = { ...configuration, draft: { ...draft, product_name: 'Mel Money' }, draft_revision: 2 }
    const previewed = { ...saved, preview_required: false, preview: { digest: 'exact', draft_revision: 2, generated_at: '2026-10-04T00:00:00Z' } }
    vi.mocked(api.saveWorkspaceBrand).mockResolvedValue(saved)
    vi.mocked(api.previewWorkspaceBrand).mockResolvedValue({ brand_configuration: previewed, preview: { ...previewed.preview, brand: saved.draft } })
    vi.mocked(api.publishWorkspaceBrand).mockResolvedValue({ brand_configuration: { ...previewed, published_version: { ...configuration.published_version!, id: 2, number: 2 } }, published_version: { ...configuration.published_version!, id: 2, number: 2 } })
    renderSettings()
    const name = await screen.findByLabelText('App name')
    expect((screen.getByRole('button', { name: 'Publish branding' }) as HTMLButtonElement).disabled).toBe(true)
    await user.clear(name); await user.type(name, 'Mel Money')
    expect((screen.getByRole('button', { name: 'Preview welcome screen' }) as HTMLButtonElement).disabled).toBe(true)
    await user.click(screen.getByRole('button', { name: 'Save brand draft' }))
    await waitFor(() => expect(api.saveWorkspaceBrand).toHaveBeenCalledWith(saved.draft, 1))
    await user.click(screen.getByRole('button', { name: 'Preview welcome screen' }))
    await screen.findByRole('heading', { name: 'Welcome screen preview' })
    await user.click(screen.getByRole('button', { name: 'Publish branding' }))
    await waitFor(() => expect(api.publishWorkspaceBrand).toHaveBeenCalledWith({ draft_revision: 2, preview_digest: 'exact', expected_published_version_id: 1 }, expect.any(String)))
    expect(window.confirm).toHaveBeenCalledWith(expect.stringContaining('Participants on a sealed release keep its brand'))
  })

  it('reviewers can preview but cannot edit program identity or brand fields', async () => {
    vi.mocked(api.fetchCoachWorkspaceSettings).mockResolvedValue({ ...workspace, permissions: { manage: false } })
    vi.mocked(api.fetchWorkspaceBrand).mockResolvedValue({ ...configuration, permissions: { edit: false, preview: true, publish: true, rollback: true } })
    renderSettings()
    const name = await screen.findByLabelText('App name')
    expect(name.closest('fieldset')?.disabled).toBe(true)
    expect(screen.getByLabelText('Workspace name').closest('fieldset')?.disabled).toBe(true)
    expect((screen.getByRole('button', { name: 'Preview welcome screen' }) as HTMLButtonElement).disabled).toBe(false)
    expect((screen.getByRole('button', { name: 'Publish branding' }) as HTMLButtonElement).disabled).toBe(true)
  })

  it('a stale save preserves unsaved input until explicit reload', async () => {
    const user = userEvent.setup()
    vi.mocked(api.saveWorkspaceBrand).mockRejectedValue(new Error('Draft changed in another session. Reload before saving.'))
    renderSettings()
    const name = await screen.findByLabelText('App name')
    await user.clear(name); await user.type(name, 'My unsaved brand')
    await user.click(screen.getByRole('button', { name: 'Save brand draft' }))
    await screen.findByRole('alert')
    expect((screen.getByLabelText('App name') as HTMLInputElement).value).toBe('My unsaved brand')
    await user.click(screen.getByRole('button', { name: 'Reload settings' }))
    await waitFor(() => expect((screen.getByLabelText('App name') as HTMLInputElement).value).toBe('Island Money'))
    expect(window.confirm).toHaveBeenCalledWith('Discard unsaved program settings and reload?')
  })

  it('a changed workspace ignores a response from a previous mutation', async () => {
    const user = userEvent.setup()
    let resolveSave!: (value: WorkspaceBrandConfiguration) => void
    vi.mocked(api.saveWorkspaceBrand).mockImplementation(() => new Promise((resolve) => { resolveSave = resolve }))
    renderSettings()
    const name = await screen.findByLabelText('App name')
    await user.type(name, ' changed')
    await user.click(screen.getByRole('button', { name: 'Save brand draft' }))
    lifecycle.isCurrent.mockReturnValueOnce(false)
    resolveSave({ ...configuration, draft: { ...draft, product_name: 'Stale other workspace' } })
    await waitFor(() => expect(lifecycle.finish).toHaveBeenCalled())
    expect((screen.getByLabelText('App name') as HTMLInputElement).value).not.toBe('Stale other workspace')
  })

  it('retries an uncertain program creation with the same key', async () => {
    const user = userEvent.setup()
    vi.mocked(api.createCoachWorkspace).mockRejectedValueOnce(new Error('Request timed out')).mockResolvedValueOnce(workspace)
    render(<CreateCoachProgram />)
    await user.click(screen.getByRole('button', { name: 'Create program' }))
    await user.type(screen.getByLabelText('Workspace name'), 'Island program')
    await user.type(screen.getByLabelText('Coach display name'), 'Mrs. Mel')
    await user.click(screen.getByRole('button', { name: 'Create program' }))
    await screen.findByRole('alert')
    await user.click(screen.getByRole('button', { name: 'Create program' }))
    await screen.findByRole('status')
    expect(vi.mocked(api.createCoachWorkspace).mock.calls[0][1]).toBe(vi.mocked(api.createCoachWorkspace).mock.calls[1][1])
  })
})
