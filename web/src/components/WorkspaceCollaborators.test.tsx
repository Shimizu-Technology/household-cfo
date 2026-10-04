// @vitest-environment jsdom
import { act, cleanup, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { WorkspaceCollaborators } from './WorkspaceCollaborators'
import { addWorkspaceCollaborator, changeWorkspaceCollaborator, fetchWorkspaceCollaborators, removeWorkspaceCollaborator, sendWorkspaceCollaboratorEmail, ApiRequestError, type WorkspaceCollaborator, type WorkspaceCollaboratorsPayload } from '../api'

vi.mock('../api', async (importOriginal) => ({
  ...await importOriginal<typeof import('../api')>(),
  fetchWorkspaceCollaborators: vi.fn(), addWorkspaceCollaborator: vi.fn(), changeWorkspaceCollaborator: vi.fn(),
  removeWorkspaceCollaborator: vi.fn(), sendWorkspaceCollaboratorEmail: vi.fn(),
}))

const owner: WorkspaceCollaborator = { id: 1, user_id: 10, email: 'owner@example.test', full_name: 'Owner', role: 'owner', status: 'accepted', platform_admin: false, is_self: true, cohort_managed: false }
const editor: WorkspaceCollaborator = { ...owner, id: 2, user_id: 11, email: 'editor@example.test', full_name: 'Editor', role: 'editor', is_self: false }
const payload = (): WorkspaceCollaboratorsPayload => ({ workspace_id: 1, permissions: { manage: true }, members: [owner, editor], sign_in_url: 'https://coach.example.test' })
const lifecycle = { pending: false, begin: vi.fn(() => ({ id: 1, workspaceId: 1 })), isCurrent: vi.fn(() => true), finish: vi.fn() }

beforeEach(() => { vi.clearAllMocks(); lifecycle.isCurrent.mockReturnValue(true); vi.mocked(fetchWorkspaceCollaborators).mockResolvedValue(payload()) })
afterEach(() => { cleanup(); vi.restoreAllMocks() })

describe('WorkspaceCollaborators', () => {
  it.each(['add', 'role', 'remove', 'email'] as const)('ignores stale %s success and clears only its owned pending operation', async (action) => {
    const user = userEvent.setup()
    vi.spyOn(window, 'confirm').mockReturnValue(true)
    let complete!: (value: never) => void
    const response = new Promise<never>((resolve) => { complete = resolve })
    vi.mocked(addWorkspaceCollaborator).mockReturnValue(response)
    vi.mocked(changeWorkspaceCollaborator).mockReturnValue(response)
    vi.mocked(removeWorkspaceCollaborator).mockReturnValue(response)
    vi.mocked(sendWorkspaceCollaboratorEmail).mockReturnValue(response)
    render(<WorkspaceCollaborators workspaceId={1} mutationLifecycle={lifecycle} />)
    const card = await screen.findByRole('region', { name: 'editor@example.test team access' })
    if (action === 'add') {
      await user.type(screen.getByRole('textbox', { name: 'Collaborator email' }), 'new@example.test')
      await user.click(screen.getByRole('button', { name: 'Add collaborator' }))
    } else if (action === 'role') {
      await user.selectOptions(within(card).getByRole('combobox'), 'reviewer')
      await user.click(within(card).getByRole('button', { name: 'Save role' }))
    } else await user.click(within(card).getByRole('button', { name: action === 'remove' ? 'Remove' : 'Send access email' }))
    lifecycle.isCurrent.mockReturnValue(false)
    await act(async () => complete({
      member: { ...editor, role: 'owner', email: 'stale@example.test' }, added: true,
      delivery: { sent: true, status: 'sent', provider_message_id: 'accepted' }, platform_admin: false,
    } as never))
    await waitFor(() => expect(lifecycle.finish).toHaveBeenCalledOnce())
    expect(screen.getByRole('button', { name: 'Refresh team' })).toHaveProperty('disabled', false)
    expect(screen.queryByRole('status')).toBeNull()
    expect(screen.queryByRole('alert')).toBeNull()
    expect(screen.queryByText('stale@example.test')).toBeNull()
    expect(screen.getByRole('region', { name: 'editor@example.test team access' })).toBeTruthy()
    if (action === 'add') expect(screen.getByRole('textbox', { name: 'Collaborator email' })).toHaveProperty('value', 'new@example.test')
    if (action === 'role') expect(within(card).getByRole('combobox')).toHaveProperty('value', 'reviewer')
  })

  it('does not release a new panel mutation when the previous program operation settles late', async () => {
    const user = userEvent.setup()
    let finishOld!: (value: Awaited<ReturnType<typeof addWorkspaceCollaborator>>) => void
    let finishNew!: (value: Awaited<ReturnType<typeof addWorkspaceCollaborator>>) => void
    vi.mocked(addWorkspaceCollaborator)
      .mockImplementationOnce(() => new Promise((resolve) => { finishOld = resolve }))
      .mockImplementationOnce(() => new Promise((resolve) => { finishNew = resolve }))
    const view = render(<WorkspaceCollaborators workspaceId={1} mutationLifecycle={lifecycle} />)
    await screen.findByRole('region', { name: 'owner@example.test team access' })
    await user.type(screen.getByRole('textbox', { name: 'Collaborator email' }), 'old@example.test')
    await user.click(screen.getByRole('button', { name: 'Add collaborator' }))
    vi.mocked(fetchWorkspaceCollaborators).mockResolvedValueOnce({ ...payload(), workspace_id: 2 })
    view.rerender(<WorkspaceCollaborators workspaceId={2} mutationLifecycle={lifecycle} />)
    await screen.findByRole('region', { name: 'owner@example.test team access' })
    await user.type(screen.getByRole('textbox', { name: 'Collaborator email' }), 'new@example.test')
    await user.click(screen.getByRole('button', { name: 'Add collaborator' }))
    const response = { member: { ...editor, id: 3, email: 'old@example.test' }, added: true, new_user: false, delivery: null, sign_in_url: null }
    await act(async () => { finishOld(response) })
    expect(screen.getByRole('button', { name: 'Saving access' })).toHaveProperty('disabled', true)
    expect(screen.queryByRole('region', { name: 'old@example.test team access' })).toBeNull()
    await act(async () => { finishNew({ ...response, member: { ...response.member, email: 'new@example.test' } }) })
    await screen.findByRole('region', { name: 'new@example.test team access' })
    expect(screen.getByRole('button', { name: 'Add collaborator' })).toHaveProperty('disabled', true)
  })

  it('protects your own owner access and explains roles without exposing financial records', async () => {
    render(<WorkspaceCollaborators workspaceId={1} mutationLifecycle={lifecycle} />)
    const card = await screen.findByRole('region', { name: 'owner@example.test team access' })
    expect(within(card).getByRole('combobox')).toHaveProperty('disabled', true)
    expect(within(card).getByRole('button', { name: 'Remove' })).toHaveProperty('disabled', true)
    expect(screen.getByText('Team access controls coaching configuration. It does not share participant financial records.')).toBeTruthy()
    expect(screen.getByRole('combobox', { name: 'Access role' })).toHaveProperty('value', 'viewer')
  })

  it('reports failed email confirmation after saved access and does not imply delivery', async () => {
    const added: WorkspaceCollaborator = { ...editor, id: 3, user_id: 12, email: 'new@example.test', full_name: 'new', role: 'viewer', status: 'pending' }
    vi.mocked(addWorkspaceCollaborator).mockResolvedValue({ member: added, added: true, new_user: true, delivery: { sent: false, status: 'failed', provider_message_id: null }, sign_in_url: 'https://coach.example.test' })
    const input = userEvent.setup()
    const dirty = vi.fn()
    render(<WorkspaceCollaborators workspaceId={1} mutationLifecycle={lifecycle} onDirtyChange={dirty} />)
    await screen.findByRole('region', { name: 'owner@example.test team access' })
    await input.type(screen.getByRole('textbox', { name: 'Collaborator email' }), 'new@example.test')
    await input.click(screen.getByRole('button', { name: 'Add collaborator' }))
    await screen.findByRole('region', { name: 'new@example.test team access' })
    expect(screen.getByRole('status').textContent).toContain('Access was saved, but the email could not be confirmed')
    expect(vi.mocked(addWorkspaceCollaborator)).toHaveBeenCalledWith(1, 'new@example.test', 'viewer', true)
    await waitFor(() => expect(dirty).toHaveBeenLastCalledWith(false))
    expect(lifecycle.finish).toHaveBeenCalled()
  })

  it('preserves a selected role after conflict and releases busy controls', async () => {
    vi.spyOn(window, 'confirm').mockReturnValue(true)
    vi.mocked(changeWorkspaceCollaborator).mockRejectedValue(new Error('This collaborator changed in another session. Refresh before trying again.'))
    const input = userEvent.setup()
    render(<WorkspaceCollaborators workspaceId={1} mutationLifecycle={lifecycle} />)
    const card = await screen.findByRole('region', { name: 'editor@example.test team access' })
    await input.selectOptions(within(card).getByRole('combobox'), 'reviewer')
    await input.click(within(card).getByRole('button', { name: 'Save role' }))
    expect((await screen.findByRole('alert')).textContent).toContain('changed in another session')
    expect(within(card).getByRole('combobox')).toHaveProperty('value', 'reviewer')
    expect(within(card).getByRole('button', { name: 'Save role' })).toHaveProperty('disabled', false)
    vi.mocked(fetchWorkspaceCollaborators).mockResolvedValue({ ...payload(), members: [owner, { ...editor, role: 'reviewer' }] })
    await input.click(screen.getByRole('button', { name: 'Refresh team' }))
    await waitFor(() => expect(within(screen.getByRole('region', { name: 'editor@example.test team access' })).getByRole('combobox')).toHaveProperty('value', 'reviewer'))
    expect(within(screen.getByRole('region', { name: 'editor@example.test team access' })).getByRole('button', { name: 'Save role' })).toHaveProperty('disabled', true)
  })

  it('clears team data when refreshed permission is revoked', async () => {
    const input = userEvent.setup()
    render(<WorkspaceCollaborators workspaceId={1} mutationLifecycle={lifecycle} />)
    await screen.findByRole('region', { name: 'owner@example.test team access' })
    vi.mocked(fetchWorkspaceCollaborators).mockRejectedValue(new ApiRequestError('Unavailable', { status: 404 }))
    await input.click(screen.getByRole('button', { name: 'Refresh team' }))
    await screen.findByText('Workspace owners and platform administrators manage collaborators.')
    expect(screen.queryByText('owner@example.test')).toBeNull()
    expect(screen.queryByRole('button', { name: 'Add collaborator' })).toBeNull()
  })

  it('does not expose team details to a role denied by the server', async () => {
    vi.mocked(fetchWorkspaceCollaborators).mockRejectedValue(new ApiRequestError('Unavailable', { status: 404 }))
    render(<WorkspaceCollaborators workspaceId={1} mutationLifecycle={lifecycle} />)
    await screen.findByText('Workspace owners and platform administrators manage collaborators.')
    expect(screen.queryByRole('textbox', { name: 'Collaborator email' })).toBeNull()
    expect(screen.queryByText('owner@example.test')).toBeNull()
  })

  it('drops a late previous-workspace roster after switching programs', async () => {
    let finishOld: ((data: WorkspaceCollaboratorsPayload) => void) | undefined
    vi.mocked(fetchWorkspaceCollaborators).mockImplementationOnce(() => new Promise((resolve) => { finishOld = resolve }))
    vi.mocked(fetchWorkspaceCollaborators).mockResolvedValueOnce({ ...payload(), workspace_id: 2, members: [{ ...editor, email: 'partner@example.test' }] })
    const view = render(<WorkspaceCollaborators workspaceId={1} mutationLifecycle={lifecycle} />)
    view.rerender(<WorkspaceCollaborators workspaceId={2} mutationLifecycle={lifecycle} />)
    await screen.findByRole('region', { name: 'partner@example.test team access' })
    finishOld?.(payload())
    await waitFor(() => expect(screen.queryByText('owner@example.test')).toBeNull())
    expect(screen.getByRole('region', { name: 'partner@example.test team access' })).toBeTruthy()
  })
})
