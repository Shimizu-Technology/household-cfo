// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as api from '../api'
import { NEUTRAL_BRAND } from '../contexts/brandContextValue'
import { BrandWelcomePreview, CoachProgramSettings, CreateCoachProgram } from './CoachProgramSettings'
import type { CurrentUser, WorkspaceBrandConfiguration, CoachWorkspaceSettings } from '../api'

vi.mock('../api', async (importOriginal) => ({
  ...await importOriginal<typeof import('../api')>(),
  fetchCoachWorkspaceSettings: vi.fn(), fetchWorkspaceBrand: vi.fn(),
  updateCoachWorkspaceSettings: vi.fn(), saveWorkspaceBrand: vi.fn(),
  previewWorkspaceBrand: vi.fn(), publishWorkspaceBrand: vi.fn(),
  restoreWorkspaceBrandVersion: vi.fn(), createCoachWorkspace: vi.fn(), uploadWorkspaceBrandLogo: vi.fn(),
}))
const workspace: CoachWorkspaceSettings = { id: 1, name: 'Island program', slug: 'island', membership_role: 'owner', coach_profile: { display_name: 'Mrs. Mel', title: 'Financial coach', bio: '' }, revision: 0, permissions: { manage: true } }
const actor = { is_admin: false, full_name: 'Mrs. Mel' } as CurrentUser
const draft = { ...NEUTRAL_BRAND, product_name: 'Island Money', short_name: 'Island', organization_name: 'Mel', welcome_heading: 'Welcome', welcome_description: 'One step at a time.' }
const configuration: WorkspaceBrandConfiguration = { workspace: { id: 1, name: workspace.name, slug: workspace.slug }, draft, draft_revision: 1, preview_required: true, preview: null, published_version: { id: 1, number: 1, digest: 'initial', published_at: '2026-10-01T00:00:00Z', published_by: { id: 1, full_name: 'Mrs. Mel' } }, versions: [], permissions: { edit: true, preview: true, publish: true, rollback: true } }
const lifecycle = { pending: false, begin: vi.fn(() => ({ id: 1, workspaceId: 1 })), isCurrent: vi.fn(() => true), finish: vi.fn() }
const refreshCurrentUser = vi.hoisted(() => vi.fn())
const selectCoachWorkspace = vi.hoisted(() => vi.fn())
vi.mock('../contexts/authContextValue', () => ({ useAuthContext: () => ({ refreshCurrentUser, selectCoachWorkspace }) }))
function renderSettings() { render(<CoachProgramSettings workspaceId={1} currentUser={actor} mutationLifecycle={lifecycle} onDirtyChange={vi.fn()} />) }

describe('program settings', () => {
  beforeEach(() => {
    vi.resetAllMocks()
    refreshCurrentUser.mockResolvedValue(undefined)
    lifecycle.begin.mockReturnValue({ id: 1, workspaceId: 1 }); lifecycle.isCurrent.mockReturnValue(true)
    vi.mocked(api.fetchCoachWorkspaceSettings).mockResolvedValue(workspace)
    vi.mocked(api.fetchWorkspaceBrand).mockResolvedValue(configuration)
    vi.spyOn(window, 'confirm').mockReturnValue(true)
  })
  afterEach(() => { cleanup(); vi.restoreAllMocks() })

  it('opens simple program creation with the current coach and selects the saved program', async () => {
    vi.mocked(api.createCoachWorkspace).mockResolvedValue(workspace)
    render(<CoachProgramSettings simple workspaceId={null} currentUser={{ ...actor, is_admin: true }} mutationLifecycle={lifecycle} onDirtyChange={vi.fn()} />)
    expect(screen.getByLabelText('Coach display name')).toHaveProperty('value', 'Mrs. Mel')
    await userEvent.type(screen.getByLabelText('Program name'), 'Island program')
    await userEvent.click(screen.getByRole('button', { name: 'Create program' }))
    await waitFor(() => expect(selectCoachWorkspace).toHaveBeenCalledWith(workspace.id))
    expect(api.createCoachWorkspace).toHaveBeenCalledWith(expect.objectContaining({ coach_profile: expect.objectContaining({ display_name: 'Mrs. Mel' }) }), expect.any(String))
  })

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
    expect(window.confirm).toHaveBeenCalledWith(expect.stringContaining('Participants keep the appearance saved for their group'))
  })

  it('reviewers can preview but cannot edit program identity or brand fields', async () => {
    vi.mocked(api.fetchCoachWorkspaceSettings).mockResolvedValue({ ...workspace, permissions: { manage: false } })
    vi.mocked(api.fetchWorkspaceBrand).mockResolvedValue({ ...configuration, permissions: { edit: false, preview: true, publish: true, rollback: true } })
    renderSettings()
    const name = await screen.findByLabelText('App name')
    expect(name.closest('fieldset')?.disabled).toBe(true)
    expect(screen.getByLabelText('Program name').closest('fieldset')?.disabled).toBe(true)
    expect(screen.getByText('Ask a program owner to change the name or coach profile.')).toBeTruthy()
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

  it('names the coach owner when creating a program and reports an invitation', async () => {
    const user = userEvent.setup()
    vi.mocked(api.createCoachWorkspace).mockResolvedValue({ ...workspace, owner_invitation: { email: 'mel@example.test', delivery: { sent: true } } })
    render(<CreateCoachProgram />)
    await user.click(screen.getByRole('button', { name: 'Create program' }))
    await user.type(screen.getByLabelText('Program name'), 'Island program')
    await user.type(screen.getByLabelText('Coach display name'), 'Mrs. Mel')
    expect(screen.getByText(/Double-check this email: the owner will see this program's participant roster/)).toBeTruthy()
    await user.type(screen.getByLabelText(/Program owner email/), ' mel@example.test ')
    await user.click(screen.getByRole('button', { name: 'Create program' }))
    expect((await screen.findByRole('status')).textContent).toContain('mel@example.test was invited as its owner and emailed')
    expect(vi.mocked(api.createCoachWorkspace).mock.calls[0][0]).toMatchObject({ owner_email: 'mel@example.test' })
  })

  it('lets a first admin invite the owner without sending email and resets the choice', async () => {
    const user = userEvent.setup()
    vi.mocked(api.createCoachWorkspace).mockResolvedValue({ ...workspace, owner_invitation: { email: 'mel@example.test', delivery: { sent: false, status: 'skipped' } } })
    render(<CreateCoachProgram firstProgram />)
    expect(screen.getByRole('heading', { name: 'Create your first program' })).toBeTruthy()
    await user.click(screen.getByRole('button', { name: 'Create program' }))
    await user.type(screen.getByLabelText('Program name'), 'Island program')
    await user.type(screen.getByLabelText('Coach display name'), 'Mrs. Mel')
    await user.type(screen.getByLabelText(/Program owner email/), 'mel@example.test')
    await user.click(screen.getByRole('checkbox', { name: 'Send invite email now' }))
    await user.click(screen.getByRole('button', { name: 'Create program' }))
    expect((await screen.findByRole('status')).textContent).toContain('No email was sent')
    expect(api.createCoachWorkspace).toHaveBeenCalledWith(expect.objectContaining({ send_invitation_email: false }), expect.any(String))
    await user.click(screen.getByRole('button', { name: 'Create program' }))
    expect(screen.getByRole('checkbox', { name: 'Send invite email now' })).toHaveProperty('checked', true)
  })

  it('retries an uncertain program creation with the same key and shows its skipped-email result', async () => {
    const user = userEvent.setup()
    vi.mocked(api.createCoachWorkspace).mockRejectedValueOnce(new Error('Request timed out')).mockResolvedValueOnce({ ...workspace, owner_invitation: { email: 'mel@example.test', delivery: { sent: false, status: 'skipped' } } })
    render(<CreateCoachProgram />)
    await user.click(screen.getByRole('button', { name: 'Create program' }))
    await user.type(screen.getByLabelText('Program name'), 'Island program')
    await user.type(screen.getByLabelText('Coach display name'), 'Mrs. Mel')
    await user.type(screen.getByLabelText(/Program owner email/), 'mel@example.test')
    await user.click(screen.getByRole('checkbox', { name: 'Send invite email now' }))
    await user.click(screen.getByRole('button', { name: 'Create program' }))
    await screen.findByRole('alert')
    await waitFor(() => expect(screen.getByRole('button', { name: 'Create program' })).toHaveProperty('disabled', false))
    await user.click(screen.getByRole('button', { name: 'Create program' }))
    expect((await screen.findByRole('status')).textContent).toContain('mel@example.test was invited as its owner. No email was sent; share their sign-in link yourself.')
    expect(api.createCoachWorkspace).toHaveBeenLastCalledWith(expect.objectContaining({ owner_email: 'mel@example.test', send_invitation_email: false }), expect.any(String))
    expect(vi.mocked(api.createCoachWorkspace).mock.calls[0][1]).toBe(vi.mocked(api.createCoachWorkspace).mock.calls[1][1])
  })

  it('keeps a confirmed program creation successful when only account refresh fails', async () => {
    const user = userEvent.setup()
    vi.mocked(api.createCoachWorkspace).mockResolvedValue(workspace)
    refreshCurrentUser.mockRejectedValue(new Error('Refresh unavailable'))
    const created = vi.fn()
    render(<CreateCoachProgram onCreated={created} />)
    await user.click(screen.getByRole('button', { name: 'Create program' }))
    await user.type(screen.getByLabelText('Program name'), 'Island program')
    await user.type(screen.getByLabelText('Coach display name'), 'Mrs. Mel')
    await user.click(screen.getByRole('button', { name: 'Create program' }))
    expect((await screen.findByRole('status')).textContent).toContain('was created')
    await waitFor(() => expect(screen.getByRole('status').textContent).toContain('do not create it again'))
    expect(screen.queryByRole('alert')).toBeNull()
    expect(screen.queryByLabelText('Program name')).toBeNull()
    expect(created).toHaveBeenCalledWith(workspace)
    expect(api.createCoachWorkspace).toHaveBeenCalledOnce()
  })

  it('keeps the saved identity revision and dirty state when only account refresh fails', async () => {
    const user = userEvent.setup()
    const saved = { ...workspace, name: 'Updated program', revision: 1 }
    vi.mocked(api.updateCoachWorkspaceSettings).mockResolvedValue(saved)
    refreshCurrentUser.mockRejectedValue(new Error('Refresh unavailable'))
    const dirty = vi.fn()
    render(<CoachProgramSettings workspaceId={1} currentUser={actor} mutationLifecycle={lifecycle} onDirtyChange={dirty} />)
    const name = await screen.findByLabelText('Program name')
    await user.clear(name); await user.type(name, saved.name)
    await user.click(screen.getByRole('button', { name: 'Save program identity' }))
    await waitFor(() => expect(screen.getByRole('status').textContent).toContain('Program identity saved, but'))
    expect(screen.queryByRole('alert')).toBeNull()
    expect(screen.getByLabelText('Program name')).toHaveProperty('value', saved.name)
    expect(screen.getByRole('button', { name: 'Save program identity' })).toHaveProperty('disabled', true)
    expect(dirty).toHaveBeenLastCalledWith(false)
    await user.type(screen.getByLabelText('Program name'), ' again')
    await user.click(screen.getByRole('button', { name: 'Save program identity' }))
    expect(vi.mocked(api.updateCoachWorkspaceSettings).mock.calls[1][1].revision).toBe(1)
  })
  it('explains unchanged saves and restores the saved identity after reopening settings', async () => {
    const user = userEvent.setup()
    const saved = { ...workspace, name: 'Mel’s Bank of Guam program', revision: 1 }
    vi.mocked(api.updateCoachWorkspaceSettings).mockResolvedValue(saved)
    const view = render(<CoachProgramSettings workspaceId={1} currentUser={actor} mutationLifecycle={lifecycle} onDirtyChange={vi.fn()} />)
    const name = await screen.findByLabelText('Program name')
    expect(screen.getByText('Your program identity is saved. Change a field to save again.')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Save program identity' })).toHaveProperty('disabled', true)
    await user.clear(name); await user.type(name, saved.name)
    await user.click(screen.getByRole('button', { name: 'Save program identity' }))
    await waitFor(() => expect(api.updateCoachWorkspaceSettings).toHaveBeenCalledWith(1, expect.objectContaining({ name: saved.name, revision: 0 })))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Save program identity' })).toHaveProperty('disabled', true))
    view.unmount()
    vi.mocked(api.fetchCoachWorkspaceSettings).mockResolvedValue(saved)
    renderSettings()
    expect(await screen.findByLabelText('Program name')).toHaveProperty('value', saved.name)
    expect(screen.getByRole('option', { name: 'System serif' })).toBeTruthy()
    expect(screen.getByText('Fonts and support details').closest('details')).toHaveProperty('open', false)
  })

  it('explains actual publishing permission even when a saved preview exists on the server', async () => {
    vi.mocked(api.fetchWorkspaceBrand).mockResolvedValue({ ...configuration, preview_required: false, preview: { digest: 'old', draft_revision: 1, generated_at: '2026-10-22' }, permissions: { ...configuration.permissions, publish: false } })
    renderSettings()
    await screen.findByLabelText('App name')
    expect(screen.getByText('A program owner or reviewer must publish this appearance.')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Publish branding' })).toHaveProperty('disabled', true)
  })

  it('uploads a logo into the saved draft and requires a new preview before publishing', async () => {
    const user = userEvent.setup()
    const previewed = { ...configuration, preview_required: false, preview: { digest: 'before', draft_revision: 1, generated_at: '2026-11-02' } }
    vi.mocked(api.fetchWorkspaceBrand).mockResolvedValue(previewed)
    vi.mocked(api.previewWorkspaceBrand).mockResolvedValue({ brand_configuration: previewed, preview: { ...previewed.preview, brand: draft } })
    const uploaded = { ...configuration, draft_revision: 2, draft: { ...draft, logo_url: 'https://api.example.test/api/public/brand_logos/signed-logo' } }
    vi.mocked(api.uploadWorkspaceBrandLogo).mockResolvedValue(uploaded)
    renderSettings()
    const input = await screen.findByLabelText('Program logo')
    expect(screen.queryByLabelText('Logo image URL')).toBeNull()
    expect(screen.getByText('More colours').closest('details')).toHaveProperty('open', false)
    expect(screen.getByText('More colours').closest('details')?.querySelectorAll('input[type="color"]')).toHaveLength(12)
    await user.click(screen.getByRole('button', { name: 'Preview welcome screen' }))
    await screen.findByRole('heading', { name: 'Welcome screen preview' })
    expect(screen.getByRole('button', { name: 'Publish branding' })).toHaveProperty('disabled', false)
    const file = new File(['png bytes'], 'logo.png', { type: 'image/png' })
    await user.upload(input, file)
    await waitFor(() => expect(api.uploadWorkspaceBrandLogo).toHaveBeenCalledWith(file, 1))
    await screen.findByText('Logo saved to your appearance draft. Preview it before publishing.')
    expect(screen.getByRole('button', { name: 'Publish branding' })).toHaveProperty('disabled', true)
    expect(screen.queryByRole('heading', { name: 'Welcome screen preview' })).toBeNull()
    expect(screen.getByRole('button', { name: 'Save brand draft' })).toHaveProperty('disabled', true)
    expect(document.querySelector('.shell-brand-logo')).toHaveProperty('src', uploaded.draft.logo_url)
  })

  it('keeps unsaved appearance changes and disallows an upload that would overwrite them', async () => {
    const user = userEvent.setup()
    renderSettings()
    const name = await screen.findByLabelText('App name')
    await user.type(name, ' unsaved')
    expect(screen.getByLabelText('Program logo')).toHaveProperty('disabled', true)
    expect(screen.getByText('Save your appearance changes before uploading a logo.')).toBeTruthy()
    expect(api.uploadWorkspaceBrandLogo).not.toHaveBeenCalled()
    expect(name).toHaveProperty('value', 'Island Money unsaved')
  })

  it('allows retrying the same file after a failed upload and ignores a stale workspace response', async () => {
    const user = userEvent.setup()
    let resolveUpload!: (value: WorkspaceBrandConfiguration) => void
    vi.mocked(api.uploadWorkspaceBrandLogo).mockRejectedValueOnce(new Error('Your logo could not be stored. Try again later.'))
      .mockImplementationOnce(() => new Promise(resolve => { resolveUpload = resolve }))
    renderSettings()
    const input = await screen.findByLabelText('Program logo')
    const file = new File(['png bytes'], 'logo.png', { type: 'image/png' })
    await user.upload(input, file)
    expect((await screen.findByRole('alert')).textContent).toContain('Your logo could not be stored')
    await waitFor(() => expect(input.closest('fieldset')).toHaveProperty('disabled', false))
    await user.upload(input, file)
    await waitFor(() => expect(api.uploadWorkspaceBrandLogo).toHaveBeenCalledTimes(2))
    lifecycle.isCurrent.mockReturnValue(false)
    resolveUpload({ ...configuration, draft: { ...draft, logo_url: 'https://other-workspace.test/logo.png' } })
    await waitFor(() => expect(lifecycle.finish).toHaveBeenCalledTimes(2))
    expect(document.querySelector('.shell-brand-logo')).toBeNull()
  })

  it('rejects oversized or non PNG files before uploading', async () => {
    const user = userEvent.setup({ applyAccept: false })
    renderSettings()
    const input = await screen.findByLabelText('Program logo')
    await user.upload(input, new File(['<svg/>'], 'logo.svg', { type: 'image/svg+xml' }))
    expect((await screen.findByRole('alert')).textContent).toContain('Choose a PNG logo')
    await user.upload(input, new File([new Uint8Array(2 * 1024 * 1024 + 1)], 'huge.png', { type: 'image/png' }))
    expect(api.uploadWorkspaceBrandLogo).not.toHaveBeenCalled()
  })

  it('removes the logo as an unsaved draft change', async () => {
    const user = userEvent.setup()
    vi.mocked(api.fetchWorkspaceBrand).mockResolvedValue({ ...configuration, draft: { ...draft, logo_url: 'https://api.example.test/logo.png' } })
    renderSettings()
    await screen.findByLabelText('Program logo')
    await user.click(screen.getByRole('button', { name: 'Remove logo' }))
    expect(document.querySelector('.shell-brand-logo')).toBeNull()
    expect(screen.getByRole('button', { name: 'Save brand draft' })).toHaveProperty('disabled', false)
    expect(api.saveWorkspaceBrand).not.toHaveBeenCalled()
  })

})

describe('welcome screen preview', () => {
  afterEach(cleanup)
  it('shows what a signed-out visitor sees: the name, the promise, both ways in and the invitation hint', () => {
    render(<BrandWelcomePreview config={{ ...draft, organization_name: 'Mel Island Money', welcome_heading: 'Welcome to your money', welcome_description: 'One clear step at a time.' }} />)
    const preview = document.querySelector('.program-preview')!
    expect(preview.querySelector('header')!.textContent).toContain('Mel Island Money')
    expect(preview.querySelector('h4')!.textContent).toBe('Welcome to your money')
    expect(screen.getByText('One clear step at a time.')).toBeTruthy()
    expect(Array.from(preview.querySelectorAll('.program-preview-action')).map(action => action.textContent)).toEqual(['Sign in', 'Create invited account'])
    expect(screen.getByText('Use the email your invitation was sent to.')).toBeTruthy()
    expect(screen.queryByText('Get started')).toBeNull()
  })

  it('falls back the way the real landing page does when the coach has not written a welcome', () => {
    render(<BrandWelcomePreview config={{ ...draft, organization_name: '', product_name: 'Island Money', welcome_heading: null, welcome_description: null, tagline: 'Run your home well' }} />)
    const preview = document.querySelector('.program-preview')!
    expect(preview.querySelector('header')!.textContent).toContain('Island Money')
    expect(preview.querySelector('h4')!.textContent).toBe('Welcome to Island Money.')
    expect(screen.getByText('Run your home well')).toBeTruthy()
  })
})
