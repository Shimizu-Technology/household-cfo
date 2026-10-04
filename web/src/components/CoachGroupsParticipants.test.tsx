// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AdminCohort, AdminUser, CurrentUser } from '../api'
import { CoachGroupsParticipants } from './CoachGroupsParticipants'
const mocks = vi.hoisted(() => ({ createAdminCohort: vi.fn(), createAdminUser: vi.fn(), fetchAdminCohorts: vi.fn(), fetchAdminUsers: vi.fn(), removeCoachGroupParticipant: vi.fn(), resendAdminUserInvitation: vi.fn(), updateAdminCohort: vi.fn() }))
vi.mock('../api', async (original) => ({ ...await original<typeof import('../api')>(), ...mocks }))
const group = { id: 10, name: 'Tuesday group', status: 'enrolling', starts_on: null, ends_on: null, notes: '', participant_count: 1, updated_at: '2026-10-04T12:00:00.000Z' } as AdminCohort
const participant = { id: 40, email: 'participant@example.com', full_name: 'Pat', is_participant: true, invitation_status: 'pending', can_resend_invitation: true, cohorts: [{ id: 100, role: 'participant', cohort: { id: 10, name: 'Tuesday group', status: 'enrolling' } }], workspace: { setup_complete: false } } as AdminUser
const owner = { is_admin: false, coach_workspaces: [{ id: 2, membership_role: 'owner' }] } as CurrentUser
function harness(user = owner, workspaceId: number | null = 2) {
  const lifecycle = { pending: false, begin: vi.fn(() => ({ id: 1, workspaceId })), isCurrent: vi.fn(() => true), finish: vi.fn() }
  const dirty = vi.fn()
  const changed = vi.fn()
  const props = { currentUser: user, workspaceId, mutationLifecycle: lifecycle, onDirtyChange: dirty, onGroupsChanged: changed }
  const result = render(<CoachGroupsParticipants {...props} />)
  return { ...result, lifecycle, dirty, changed, props }
}
beforeEach(() => {
  vi.resetAllMocks()
  mocks.fetchAdminCohorts.mockResolvedValue([group])
  mocks.fetchAdminUsers.mockResolvedValue([participant])
})
afterEach(() => cleanup())
describe('Coach group essentials', () => {
  it('blocks collaborators and platform mode without fetching participant identities', async () => {
    for (const role of ['editor', 'reviewer', 'viewer']) {
      const view = harness({ ...owner, coach_workspaces: [{ id: 2, membership_role: role }] } as CurrentUser)
      expect(screen.getByText(/does not include roster access/)).toBeTruthy()
      view.unmount()
    }
    harness(owner, null)
    expect(screen.getByText(/Choose a program/)).toBeTruthy()
    expect(mocks.fetchAdminUsers).not.toHaveBeenCalled()
  })
  it('saves group changes with the revision from its loaded snapshot', async () => {
    const user = userEvent.setup()
    mocks.updateAdminCohort.mockResolvedValue({ ...group, name: 'Evening group' })
    const { dirty } = harness()
    await screen.findByText('Participants in Tuesday group')
    await user.clear(screen.getByLabelText('Group name'))
    await user.type(screen.getByLabelText('Group name'), 'Evening group')
    expect(dirty).toHaveBeenLastCalledWith(true)
    await user.click(screen.getByRole('button', { name: 'Save group' }))
    expect(mocks.updateAdminCohort).toHaveBeenCalledWith(10, expect.objectContaining({ name: 'Evening group', expected_updated_at: group.updated_at }))
    await screen.findByText(/Group saved/)
  })
  it('reports failed email accurately and prevents another click repeating a completed add', async () => {
    const user = userEvent.setup()
    mocks.createAdminUser.mockResolvedValue({ user: participant, invitation_sent: false, invitation_status: 'failed', invitation_error: 'Email provider unavailable.' })
    const { lifecycle } = harness()
    await screen.findByText('Participants in Tuesday group')
    await user.type(screen.getByLabelText('Participant email'), 'new@example.com')
    await user.click(screen.getByRole('button', { name: 'Add to Tuesday group' }))
    await screen.findByText(/Participant added, but the invitation email failed/)
    expect(mocks.createAdminUser).toHaveBeenCalledWith({ email: 'new@example.com', role: 'participant', cohort_id: 10, send_invitation_email: true })
    expect((screen.getByLabelText('Participant email') as HTMLInputElement).value).toBe('')
    expect(lifecycle.finish).toHaveBeenCalled()
  })
  it('creates an enrolling group and never promotes a participant or launches a release', async () => {
    const user = userEvent.setup()
    mocks.createAdminCohort.mockResolvedValue({ ...group, id: 11, name: 'Saturday' })
    harness()
    await screen.findByText('Participants in Tuesday group')
    await user.click(screen.getByRole('button', { name: 'New group' }))
    await user.type(screen.getAllByLabelText('Group name')[0], 'Saturday')
    await user.click(screen.getByRole('button', { name: 'Create group' }))
    await screen.findByText(/Group created/)
    expect(mocks.createAdminCohort).toHaveBeenCalledWith({ name: 'Saturday', status: 'enrolling' })
    expect(mocks.createAdminUser).not.toHaveBeenCalled()
  })
  it('confirms one enrollment removal with its membership snapshot', async () => {
    const user = userEvent.setup()
    mocks.removeCoachGroupParticipant.mockResolvedValue({ removed: true, cohort_id: 10 })
    harness()
    await screen.findByText('Participants in Tuesday group')
    await user.click(screen.getByRole('button', { name: 'Cancel enrollment' }))
    expect(mocks.removeCoachGroupParticipant).not.toHaveBeenCalled()
    expect(screen.getByText(/Their account and other group memberships stay available/)).toBeTruthy()
    await user.click(screen.getByRole('button', { name: 'Confirm removal' }))
    await screen.findByText(/Enrollment removed from this group/)
    expect(mocks.removeCoachGroupParticipant).toHaveBeenCalledWith(10, 40, 100)
  })
  it('discards a late completed write after workspace selection has changed', async () => {
    const user = userEvent.setup()
    let resolve!: (value: unknown) => void
    mocks.createAdminUser.mockImplementation(() => new Promise((done) => { resolve = done }))
    const { lifecycle } = harness()
    await screen.findByText('Participants in Tuesday group')
    await user.type(screen.getByLabelText('Participant email'), 'new@example.com')
    await user.click(screen.getByRole('button', { name: 'Add to Tuesday group' }))
    lifecycle.isCurrent.mockReturnValue(false)
    resolve({ user: participant, invitation_sent: true, invitation_status: 'sent' })
    await waitFor(() => expect(lifecycle.finish).toHaveBeenCalled())
    expect(screen.queryByText('Participant added. Invitation email sent.')).toBeNull()
    expect(mocks.fetchAdminCohorts).toHaveBeenCalledTimes(1)
  })
})
