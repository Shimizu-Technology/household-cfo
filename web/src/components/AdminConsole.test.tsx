// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AdminCohort, AdminUser, CurrentUser } from '../api'
import { AdminConsole } from './AdminConsole'
const mocks = vi.hoisted(() => ({ fetchAdminCohorts: vi.fn(), fetchAdminUsers: vi.fn(), fetchAdminPlaidHealth: vi.fn(), updateAdminUser: vi.fn(), resendAdminUserInvitation: vi.fn(), createAdminUser: vi.fn(), createAdminCohort: vi.fn(), updateAdminCohort: vi.fn() }))
vi.mock('../api', async (original) => ({ ...await original<typeof import('../api')>(), ...mocks }))
const supportMocks = vi.hoisted(() => ({ fetchSetupSupportRequests: vi.fn(), updateSetupSupportRequest: vi.fn() }))
vi.mock('../setupHelpApi', () => supportMocks)
const authScope = vi.hoisted(() => ({ workspaceId: 2 as number | null, selectCoachWorkspace: vi.fn() }))
vi.mock('../contexts/authContextValue', () => ({ useAuthContext: () => ({ activeCoachWorkspaceId: authScope.workspaceId, selectCoachWorkspace: authScope.selectCoachWorkspace }) }))
vi.mock('./PilotFeedbackInbox', () => ({ PilotFeedbackInbox: () => <section>Private support inbox</section> }))
vi.mock('./CoachProgramSettings', () => ({ CreateCoachProgram: () => <section>Create program controls</section> }))
const cohort = { id: 10, name: 'BOG 90 day challenge', status: 'enrolling', starts_on: null, ends_on: null, notes: '', updated_at: '2026-10-04T12:00:00Z' } as AdminCohort
const people = Array.from({ length: 30 }, (_, index) => ({ id: 40 + index, email: `participant${index}@example.test`, full_name: `Participant ${String(index).padStart(2, '0')}`, role: 'participant', invitation_status: 'accepted', cohorts: [{ id: 100 + index, role: 'participant', cohort: { id: 10, name: cohort.name, status: 'enrolling' } }], invite_email: { workspace_scoped: true, status: 'not_sent', last_attempted_at: null }, workspace: { setup_complete: false, setup_status: 'not_started', signed_in: true, has_pending_review_work: false, last_safe_activity_at: null } })) as AdminUser[]
beforeEach(() => { vi.resetAllMocks(); sessionStorage.clear(); authScope.workspaceId = 2; supportMocks.fetchSetupSupportRequests.mockReset(); supportMocks.updateSetupSupportRequest.mockReset(); mocks.fetchAdminCohorts.mockImplementation(async () => structuredClone([cohort])); mocks.fetchAdminUsers.mockImplementation(async () => structuredClone(people)); mocks.fetchAdminPlaidHealth.mockResolvedValue({ summary: { connected: 0, healthy: 0, attention_required: 0 }, items: [] }); vi.spyOn(window, 'confirm').mockReturnValue(false) })
afterEach(() => { cleanup(); sessionStorage.clear(); vi.restoreAllMocks() })
const actor = { id: 1, is_admin: true, coach_workspaces: [{ id: 2, name: 'Mel coaching' }] } as CurrentUser
describe('staff operation hierarchy', () => {
  it('keeps ordinary platform support reachable without the default global cohort filter', async () => {
    authScope.workspaceId = null
    supportMocks.fetchSetupSupportRequests.mockResolvedValue({ records: [], next_cursor: null })
    render(<AdminConsole currentUser={actor} />)
    await screen.findAllByText('Participant 00', {}, { timeout: 3000 })
    await waitFor(() => expect(screen.getByRole('button', { name: 'Refresh' })).toHaveProperty('disabled', false), { timeout: 3000 })
    expect(screen.getByLabelText('Cohort scope')).toHaveProperty('value', '10')
    fireEvent.click(screen.getByRole('button', { name: 'Support inbox' }))
    fireEvent.click(screen.getByRole('button', { name: 'Setup requests' }))
    await screen.findByText('Platform support requests; select a program workspace for its requests.')
    await waitFor(() => expect(supportMocks.fetchSetupSupportRequests).toHaveBeenCalledWith(null, null, expect.any(AbortSignal)))
  })
  it('loads setup requests only inside their selected support view and locks navigation during writes', async () => {
    const record = { id: 91, participant_name: 'Support participant', program_name: 'BOG', status: 'requested', reason_label: 'Practice numbers', lock_version: 2, created_at: '2026-10-07T10:00:00Z', permissions: { triage: true, prepare: true, decline: true } }
    supportMocks.fetchSetupSupportRequests.mockResolvedValue({ records: [record], next_cursor: null })
    let complete!: (value: unknown) => void
    supportMocks.updateSetupSupportRequest.mockReturnValue(new Promise((resolve) => { complete = resolve }))
    render(<AdminConsole currentUser={actor} />)
    await screen.findAllByText('Participant 00', {}, { timeout: 3000 })
    await waitFor(() => expect(screen.getByRole('button', { name: 'Refresh' })).toHaveProperty('disabled', false), { timeout: 3000 })
    expect(supportMocks.fetchSetupSupportRequests).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Support inbox' }))
    expect(screen.getByRole('button', { name: 'Problems reported' }).getAttribute('aria-pressed')).toBe('true')
    expect(supportMocks.fetchSetupSupportRequests).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Setup requests' }))
    await screen.findByText('Support participant')
    expect(supportMocks.fetchSetupSupportRequests).toHaveBeenCalledWith(10, null, expect.any(AbortSignal))
    fireEvent.click(screen.getByRole('button', { name: 'Mark in review' }))
    expect(screen.getByRole('button', { name: 'Participants & access' })).toHaveProperty('disabled', true)
    expect(screen.getByRole('button', { name: 'Problems reported' })).toHaveProperty('disabled', true)
    expect(screen.getByLabelText('Cohort scope')).toHaveProperty('disabled', true)
    expect(screen.getByLabelText(/^Admin workspace/)).toHaveProperty('disabled', true)
    await act(async () => complete({ request: { ...record, status: 'in_review', lock_version: 3 } }))
    await screen.findByText('Request #91: In review.')
    await waitFor(() => expect(screen.getByRole('button', { name: 'Participants & access' })).toHaveProperty('disabled', false))
  })
  it('pages thirty participants in fifteen compact access rows and separates support from the participant task', async () => {
    render(<AdminConsole currentUser={actor} />)
    await screen.findAllByText('Participant 00', {}, { timeout: 3000 })
    await waitFor(() => expect(screen.getByRole('button', { name: 'Refresh' })).toHaveProperty('disabled', false), { timeout: 3000 })
    expect(document.querySelectorAll('.admin-user-row')).toHaveLength(15)
    fireEvent.click(screen.getByRole('button', { name: 'Next participants' }))
    expect(document.querySelector('.admin-user-row')?.textContent).toContain('Participant 15')
    expect(screen.getByText('Page 2 of 2')).toBeTruthy()
    expect(document.querySelectorAll('.admin-user-row[open]')).toHaveLength(0)
    expect(Array.from(document.querySelectorAll('.admin-user-controls button')).every((button) => !(button.closest('details') as HTMLDetailsElement).open)).toBe(true)
    expect(screen.queryByRole('heading', { name: 'Bank feed ledger' })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Support inbox' }))
    expect(screen.getByText('Private support inbox').closest('[hidden]')).toBeNull()
    expect(document.querySelector('.admin-users-panel')?.hasAttribute('hidden')).toBe(true)
    expect(screen.queryByRole('heading', { name: /members/ })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Participants & access' }))
    expect(screen.getByRole('heading', { name: /members/ })).toBeTruthy()
    fireEvent.change(screen.getByLabelText('Search'), { target: { value: 'Participant 29' } })
    expect(document.querySelectorAll('.admin-user-row')).toHaveLength(1)
    expect(document.querySelector('.admin-user-row')?.textContent).toContain('participant29@example.test')
  })
  it('preserves the selected cohort edits and invite while creating another cohort', async () => {
    const created = { ...cohort, id: 11, name: 'New challenge group' }
    mocks.createAdminCohort.mockResolvedValue(created)
    render(<AdminConsole currentUser={actor} />)
    await screen.findAllByText('Participant 00', {}, { timeout: 3000 })
    await waitFor(() => expect(screen.getByRole('button', { name: 'Refresh' })).toHaveProperty('disabled', false), { timeout: 3000 })
    fireEvent.change(screen.getByLabelText('Email'), { target: { value: 'pending@example.test' } })
    fireEvent.click(screen.getByRole('button', { name: 'Cohorts' }))
    const editForm = screen.getByRole('button', { name: 'Save cohort' }).closest('form')!
    fireEvent.change(within(editForm).getByLabelText('Name'), { target: { value: 'Unfinished BOG name' } })
    fireEvent.change(within(editForm).getByLabelText('Notes'), { target: { value: 'Unfinished kickoff notes' } })
    fireEvent.change(within(editForm).getByLabelText('Starts'), { target: { value: '2026-10-10' } })
    mocks.fetchAdminCohorts.mockResolvedValue([cohort, created])
    fireEvent.change(screen.getByLabelText('Cohort name'), { target: { value: created.name } })
    fireEvent.click(screen.getByRole('button', { name: 'Create cohort' }))
    await screen.findByText(`${created.name} is ready for invites.`)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Create cohort' })).toHaveProperty('disabled', false))
    expect(screen.getByLabelText('Cohort scope')).toHaveProperty('value', '10')
    expect(within(editForm).getByLabelText('Name')).toHaveProperty('value', 'Unfinished BOG name')
    expect(within(editForm).getByLabelText('Notes')).toHaveProperty('value', 'Unfinished kickoff notes')
    expect(within(editForm).getByLabelText('Starts')).toHaveProperty('value', '2026-10-10')
    expect(mocks.updateAdminCohort).not.toHaveBeenCalled()
    expect(window.confirm).not.toHaveBeenCalled()
    expect(screen.getByText(`${created.name} is ready for invites.`).getAttribute('role')).toBe('status')
    fireEvent.click(screen.getByRole('button', { name: 'Participants & access' }))
    expect(screen.getByLabelText('Email')).toHaveProperty('value', 'pending@example.test')
    expect(screen.getByLabelText('Cohort (required)')).toHaveProperty('value', '10')
  }, 15_000)
  it('selects the created cohort and targets its invitations when the selected cohort edit is clean', async () => {
    const created = { ...cohort, id: 11, name: 'Next challenge group' }
    mocks.createAdminCohort.mockResolvedValue(created)
    render(<AdminConsole currentUser={actor} />)
    await screen.findAllByText('Participant 00', {}, { timeout: 3000 })
    await waitFor(() => expect(screen.getByRole('button', { name: 'Refresh' })).toHaveProperty('disabled', false), { timeout: 3000 })
    fireEvent.click(screen.getByRole('button', { name: 'Cohorts' }))
    mocks.fetchAdminCohorts.mockResolvedValue([cohort, created])
    fireEvent.change(screen.getByLabelText('Cohort name'), { target: { value: created.name } })
    fireEvent.click(screen.getByRole('button', { name: 'Create cohort' }))
    await waitFor(() => expect(screen.getByLabelText('Cohort scope')).toHaveProperty('value', '11'))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Create cohort' })).toHaveProperty('disabled', false))
    expect(screen.getByLabelText('Name')).toHaveProperty('value', created.name)
    expect(screen.getByLabelText('Cohort name')).toHaveProperty('value', '')
    fireEvent.click(screen.getByRole('button', { name: 'Participants & access' }))
    expect(screen.getByLabelText('Cohort (required)')).toHaveProperty('value', '11')
    expect(mocks.createAdminCohort).toHaveBeenCalledWith({ name: created.name, status: 'enrolling', starts_on: '', ends_on: '', notes: '' })
  })
  it('keeps another page’s unsaved edit after saving a participant', async () => {
    render(<AdminConsole currentUser={actor} />)
    await screen.findAllByText('Participant 00', {}, { timeout: 3000 })
    await waitFor(() => expect(screen.getByRole('button', { name: 'Refresh' })).toHaveProperty('disabled', false), { timeout: 3000 })
    fireEvent.click(screen.getByRole('button', { name: 'Cohorts' }))
    const cohortName = screen.getAllByLabelText('Name').find((input) => (input as HTMLInputElement).value === cohort.name)!
    fireEvent.change(cohortName, { target: { value: 'Draft BOG cohort name' } })
    fireEvent.click(screen.getByRole('button', { name: 'Participants & access' }))
    const row = document.querySelector('.admin-user-row') as HTMLDetailsElement
    row.open = true
    fireEvent.change(within(row).getByLabelText('Role'), { target: { value: 'coach' } })
    fireEvent.click(screen.getByRole('button', { name: 'Next participants' }))
    const savedRow = document.querySelector('.admin-user-row') as HTMLDetailsElement
    savedRow.open = true
    fireEvent.change(within(savedRow).getByLabelText('Role'), { target: { value: 'coach' } })
    const updated = { ...people[15], role: 'coach' } as AdminUser
    mocks.updateAdminUser.mockResolvedValue(updated)
    mocks.fetchAdminUsers.mockResolvedValue(people.map((user) => user.id === updated.id ? updated : user))
    fireEvent.click(within(savedRow).getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Previous participants' })).toHaveProperty('disabled', false))
    expect(savedRow.textContent).not.toContain('Unsaved access changes')
    fireEvent.click(screen.getByRole('button', { name: 'Previous participants' }))
    const preserved = document.querySelector('.admin-user-row') as HTMLDetailsElement
    preserved.open = true
    expect(within(preserved).getByLabelText('Role')).toHaveProperty('value', 'coach')
    expect(preserved.textContent).toContain('Unsaved access changes')
    fireEvent.click(screen.getByRole('button', { name: 'Cohorts' }))
    expect(cohortName).toHaveProperty('value', 'Draft BOG cohort name')
  }, 15_000)
  it('says an email is already invited instead of reporting an update', async () => {
    const pending = { ...people[15], invitation_status: 'pending' } as AdminUser
    mocks.createAdminUser.mockResolvedValue({ user: pending, created: false, reactivated: false, already_invited: true, invitation_sent: false, invitation_status: 'skipped' })
    render(<AdminConsole currentUser={actor} />)
    await screen.findAllByText('Participant 00', {}, { timeout: 3000 })
    await waitFor(() => expect(screen.getByRole('button', { name: 'Refresh' })).toHaveProperty('disabled', false), { timeout: 3000 })
    const form = screen.getByRole('button', { name: 'Create invite' }).closest('form')!
    fireEvent.change(within(form).getByLabelText(/Email/), { target: { value: pending.email } })
    fireEvent.submit(form)
    const notice = await screen.findByText(/was already invited/)
    expect(notice.textContent).toContain('Nothing was sent again')
    expect(notice.textContent).toContain('Resend email')
    expect(notice.textContent).not.toContain('was updated')
  })
  it('says which group an already invited email was added to', async () => {
    const pending = { ...people[15], invitation_status: 'pending' } as AdminUser
    mocks.createAdminUser.mockResolvedValue({ user: pending, created: false, reactivated: false, already_invited: true, assigned_cohort_names: ['Synthetic cohort'], invitation_sent: false, invitation_status: 'skipped' })
    render(<AdminConsole currentUser={actor} />)
    await screen.findAllByText('Participant 00', {}, { timeout: 3000 })
    await waitFor(() => expect(screen.getByRole('button', { name: 'Refresh' })).toHaveProperty('disabled', false), { timeout: 3000 })
    const form = screen.getByRole('button', { name: 'Create invite' }).closest('form')!
    fireEvent.change(within(form).getByLabelText(/Email/), { target: { value: pending.email } })
    fireEvent.submit(form)
    const notice = await screen.findByText(/was already invited/)
    expect(notice.textContent).toContain('Added to Synthetic cohort. No new email sent.')
    expect(notice.textContent).toContain('Resend email')
  })
  it('prevents a concurrent invite from superseding a participant save and its refresh', async () => {
    render(<AdminConsole currentUser={actor} />)
    await screen.findAllByText('Participant 00', {}, { timeout: 3000 })
    await waitFor(() => expect(screen.getByRole('button', { name: 'Refresh' })).toHaveProperty('disabled', false), { timeout: 3000 })
    const inviteButton = screen.getByRole('button', { name: 'Create invite' })
    const inviteForm = inviteButton.closest('form')!
    const row = document.querySelector('.admin-user-row') as HTMLDetailsElement
    row.open = true
    fireEvent.change(within(row).getByLabelText('Role'), { target: { value: 'coach' } })
    let resolveSave!: (user: AdminUser) => void
    mocks.updateAdminUser.mockImplementation(() => new Promise((resolve) => { resolveSave = resolve }))
    fireEvent.click(within(row).getByRole('button', { name: 'Save' }))
    expect(inviteButton).toHaveProperty('disabled', true)
    fireEvent.submit(inviteForm)
    expect(mocks.createAdminUser).not.toHaveBeenCalled()
    await act(async () => resolveSave({ ...people[0], role: 'coach' } as AdminUser))
    await waitFor(() => expect(inviteButton).toHaveProperty('disabled', false))
  })
  it('keeps participant drafts when an invitation resend refreshes the roster', async () => {
    const pending = { ...people[15], invitation_status: 'pending' } as AdminUser
    mocks.fetchAdminUsers.mockResolvedValue(people.map((user) => user.id === pending.id ? pending : user))
    mocks.resendAdminUserInvitation.mockResolvedValue({ user: pending, invite_email: { status: 'sent' } })
    render(<AdminConsole currentUser={actor} />)
    await screen.findAllByText('Participant 00', {}, { timeout: 3000 })
    await waitFor(() => expect(screen.getByRole('button', { name: 'Refresh' })).toHaveProperty('disabled', false), { timeout: 3000 })
    const firstRow = document.querySelector('.admin-user-row') as HTMLDetailsElement
    firstRow.open = true
    fireEvent.change(within(firstRow).getByLabelText('Role'), { target: { value: 'coach' } })
    fireEvent.click(screen.getByRole('button', { name: 'Next participants' }))
    const pendingRow = document.querySelector('.admin-user-row') as HTMLDetailsElement
    pendingRow.open = true
    fireEvent.click(within(pendingRow).getByRole('button', { name: 'Resend email' }))
    await waitFor(() => expect(mocks.fetchAdminUsers).toHaveBeenCalledTimes(2))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Previous participants' })).toHaveProperty('disabled', false))
    fireEvent.click(screen.getByRole('button', { name: 'Previous participants' }))
    const returned = document.querySelector('.admin-user-row') as HTMLDetailsElement
    returned.open = true
    expect(within(returned).getByLabelText('Role')).toHaveProperty('value', 'coach')
    expect(returned.textContent).toContain('Unsaved access changes')
  })
  it('keeps edits when the refresh after a save fails, and discards only after confirmed Refresh', async () => {
    render(<AdminConsole currentUser={actor} />)
    await screen.findAllByText('Participant 00', {}, { timeout: 3000 })
    await waitFor(() => expect(screen.getByRole('button', { name: 'Refresh' })).toHaveProperty('disabled', false), { timeout: 3000 })
    const row = document.querySelector('.admin-user-row') as HTMLDetailsElement
    row.open = true
    fireEvent.change(within(row).getByLabelText('Role'), { target: { value: 'coach' } })
    mocks.updateAdminUser.mockResolvedValue({ ...people[0], role: 'coach' })
    mocks.fetchAdminUsers.mockRejectedValueOnce(new Error('Roster unavailable'))
    fireEvent.click(within(row).getByRole('button', { name: 'Save' }))
    await screen.findByText('Roster unavailable')
    await waitFor(() => expect(screen.getByRole('button', { name: 'Refresh' })).toHaveProperty('disabled', false))
    expect(within(row).getByLabelText('Role')).toHaveProperty('value', 'coach')
    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }))
    expect(mocks.fetchAdminUsers).toHaveBeenCalledTimes(2)
    vi.mocked(window.confirm).mockReturnValue(true)
    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }))
    await waitFor(() => expect(within(row).getByLabelText('Role')).toHaveProperty('value', 'participant'))
  })
  it('retains an unsaved per-person edit across operation areas and guards cohort changes', async () => {
    render(<AdminConsole currentUser={actor} />)
    await screen.findAllByText('Participant 00', {}, { timeout: 3000 })
    await waitFor(() => expect(screen.getByRole('button', { name: 'Refresh' })).toHaveProperty('disabled', false), { timeout: 3000 })
    const row = document.querySelector('.admin-user-row') as HTMLDetailsElement
    row.open = true
    fireEvent.change(within(row).getByLabelText('Role'), { target: { value: 'coach' } })
    expect(row.textContent).toContain('Unsaved access changes')
    fireEvent.click(screen.getByRole('button', { name: 'Next participants' }))
    fireEvent.click(screen.getByRole('button', { name: 'Previous participants' }))
    const returnedRow = document.querySelector('.admin-user-row') as HTMLDetailsElement
    returnedRow.open = true
    expect(within(returnedRow).getByLabelText('Role')).toHaveProperty('value', 'coach')
    fireEvent.click(screen.getByRole('button', { name: 'Support inbox' }))
    fireEvent.click(screen.getByRole('button', { name: 'Participants & access' }))
    expect(within(returnedRow).getByLabelText('Role')).toHaveProperty('value', 'coach')
    fireEvent.change(screen.getByLabelText('Cohort scope'), { target: { value: '' } })
    expect(window.confirm).toHaveBeenCalled()
    expect(screen.getByLabelText('Cohort scope')).toHaveProperty('value', '10')
    expect(mocks.updateAdminUser).not.toHaveBeenCalled()
    await waitFor(() => expect(screen.getByRole('button', { name: 'Refresh' })).toHaveProperty('disabled', false))
  })
  it('shows scoped invitation attention and removes roster controls from unrelated areas', async () => {
    const pending = { ...people[0], invitation_status: 'pending', invite_email: { ...people[0].invite_email, status: 'failed' } } as AdminUser
    const elsewhere = { ...people[1], invitation_status: 'pending', cohorts: [] } as AdminUser
    mocks.fetchAdminUsers.mockResolvedValue([pending, elsewhere])
    render(<AdminConsole currentUser={actor} />)
    await screen.findByText('1 awaiting sign-in · 1 invitation emails need attention')
    expect(document.querySelector('.admin-stat-row')).toBeNull()
    await waitFor(() => expect(screen.getByRole('button', { name: 'Bank health' })).toHaveProperty('disabled', false))
    fireEvent.click(screen.getByRole('button', { name: 'Bank health' }))
    expect(screen.queryByLabelText('Cohort scope')).toBeNull()
    expect(screen.getByText('No active Plaid connections yet.')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Programs & rules' }))
    expect(screen.queryByLabelText('Cohort scope')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Participants & access' }))
    expect(screen.getByLabelText('Cohort scope')).toHaveProperty('value', '10')
  })
  it('offers resend only for pending eligible accounts and explains joined accounts', async () => {
    mocks.fetchAdminUsers.mockResolvedValue([
      people[0],
      { ...people[1], invitation_status: 'pending', can_resend_invitation: false },
      { ...people[2], invitation_status: 'pending', can_resend_invitation: true },
    ])
    render(<AdminConsole currentUser={actor} />)
    await screen.findByText('Participant 00')
    const rows = [...document.querySelectorAll<HTMLDetailsElement>('.admin-user-row')]
    rows.forEach((row) => { row.open = true })
    expect(within(rows[0]).queryByRole('button', { name: 'Resend email' })).toBeNull()
    expect(within(rows[0]).getByText('Already joined; an invitation email is no longer needed.')).toBeTruthy()
    expect(within(rows[1]).queryByRole('button', { name: 'Resend email' })).toBeNull()
    expect(within(rows[2]).getByRole('button', { name: 'Resend email' })).toBeTruthy()
  })
  it('puts selected challenge first and guards its review across group and workspace switches', async () => {
    mocks.fetchAdminCohorts.mockResolvedValue([{ ...cohort, savings_challenge: { state: 'open', label: 'Open', capacity: 30, participant_count: 8, can_change: true, can_pause: true, can_open: false, blockers: [], recent_events: [] } }])
    render(<AdminConsole currentUser={actor} />)
    await screen.findByText('Participant 00')
    await waitFor(() => expect(screen.getByRole('button', { name: 'Cohorts' })).toHaveProperty('disabled', false))
    fireEvent.click(screen.getByRole('button', { name: 'Cohorts' }))
    const challenge = document.querySelector('.challenge-access')!
    const create = screen.getByText('Create a cohort', { exact: true })
    expect(challenge.compareDocumentPosition(create) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Pause the challenge' }))
    fireEvent.change(screen.getByLabelText(/Reason/), { target: { value: 'Keep this review reason' } })
    fireEvent.change(screen.getByLabelText('Cohort scope'), { target: { value: '' } })
    expect(screen.getByLabelText('Cohort scope')).toHaveProperty('value', '10')
    fireEvent.change(screen.getByLabelText(/^Admin workspace/), { target: { value: 'platform' } })
    expect(authScope.selectCoachWorkspace).not.toHaveBeenCalled()
    expect(screen.getByLabelText(/Reason/)).toHaveProperty('value', 'Keep this review reason')
    fireEvent.click(screen.getByRole('button', { name: 'Participants & access' }))
    fireEvent.click(screen.getByRole('button', { name: 'Cohorts' }))
    expect(screen.getByLabelText(/Reason/)).toHaveProperty('value', 'Keep this review reason')
    vi.mocked(window.confirm).mockReturnValue(true)
    fireEvent.change(screen.getByLabelText('Cohort scope'), { target: { value: '' } })
    expect(screen.getByLabelText('Cohort scope')).toHaveProperty('value', '')
    expect(screen.queryByLabelText(/Reason/)).toBeNull()
  })
  it('discards the confirmed invitation and creation drafts when changing group', async () => {
    render(<AdminConsole currentUser={actor} />)
    await screen.findByText('Participant 00')
    await waitFor(() => expect(screen.getByRole('button', { name: 'Cohorts' })).toHaveProperty('disabled', false))
    fireEvent.change(screen.getByLabelText('Email'), { target: { value: 'unfinished@example.test' } })
    fireEvent.click(screen.getByRole('button', { name: 'Cohorts' }))
    fireEvent.change(screen.getByLabelText('Cohort name'), { target: { value: 'Unfinished group' } })
    vi.mocked(window.confirm).mockReturnValue(true)
    fireEvent.change(screen.getByLabelText('Cohort scope'), { target: { value: '' } })
    expect(screen.getByLabelText('Cohort name')).toHaveProperty('value', '')
    fireEvent.click(screen.getByRole('button', { name: 'Participants & access' }))
    expect(screen.getByLabelText('Email')).toHaveProperty('value', '')
  })

})
