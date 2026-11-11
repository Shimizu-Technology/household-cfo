// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError } from '../../api'
import { registerConfirmHost, type ConfirmRequest } from '../../lib/confirmAction'
import { adminUser, editorUser, group, person, reviewerUser, savings, staff } from '../../test/adminFixtures'

const api = vi.hoisted(() => ({ fetchAdminCohorts: vi.fn(), fetchAdminUsers: vi.fn(), fetchAdminPersonaAssignableCohorts: vi.fn(), resendAdminUserInvitation: vi.fn(), createAdminUser: vi.fn() }))
vi.mock('../../api', async original => ({ ...await original<typeof import('../../api')>(), ...api }))
const daily = vi.hoisted(() => ({ daily: vi.fn() }))
vi.mock('../../lib/coachChallengeApi', async original => ({ ...await original<typeof import('../../lib/coachChallengeApi')>(), coachChallengeApi: { daily: daily.daily } }))
vi.mock('../../contexts/authContextValue', () => ({ useAuthContext: () => ({ activeCoachWorkspaceId: 5, selectCoachWorkspace: vi.fn() }) }))
const inbox = vi.hoisted(() => ({ props: null as null | { mutationLifecycle?: { begin: () => unknown } } }))
vi.mock('../../components/SetupSupportInbox', () => ({ SetupSupportInbox: (props: { mutationLifecycle?: { begin: () => unknown } }) => { inbox.props = props; return <p>Setup request details</p> } }))
vi.mock('../../components/ParticipantHelp', () => ({ ParticipantHelp: () => <p>Shared items</p> }))
import { TodaySection } from './TodaySection'

const bog = group(2, 'Bank of Guam 90 day savings', { savings_challenge: savings('open') })
const household = group(3, 'Mel’s Household Group', { status: 'active' })
const row = (id: number, name: string, over = {}) => ({ participant: { id, name }, needs_help: true, setup_help: [{ id: 1, reason: 'upload_problem', status: 'requested' }], help_requests: [], shared_items: [], enrollment_id: null, check_in: null, membership_status: 'joined', setup_status: 'complete', ...over })
const quiet = (id: number, name: string) => row(id, name, { needs_help: false, setup_help: [], enrollment_id: 40 + id, check_in: { completed: false } })
const counts = (over = {}) => ({ all: 0, needs_help: 0, checked_in: 4, not_checked_in: 0, invited: 0, joined: 0, setup_done: 0, ...over })
const page = (id: number, records: unknown[], over: Record<string, unknown> = {}) => ({ cohort_id: id, program_type: 'savings', counts: counts({ needs_help: records.length, all: records.length }), records, total: records.length, next_offset: null, ...over })
const light = (id: number, name: string, status = 'enrolling') => ({ id, name, status, assignable: true, blocked_reason: null, persona_assignment: null })

beforeEach(() => {
  vi.resetAllMocks()
  api.fetchAdminCohorts.mockResolvedValue([bog, household])
  api.fetchAdminPersonaAssignableCohorts.mockResolvedValue([light(2, bog.name), light(3, household.name, 'active')])
  api.fetchAdminUsers.mockResolvedValue([
    person(1, 'Nora Never', { invitation_status: 'pending', can_resend_invitation: true, cohorts: [{ id: 5, role: 'participant', cohort: { id: 2, name: bog.name, status: 'enrolling' } }] }),
    person(2, 'Bea Bounced', { invitation_status: 'pending', invite_email: { status: 'failed' }, can_resend_invitation: true }),
    person(3, 'Joined Jo'),
  ])
  daily.daily.mockImplementation((id: number) => Promise.resolve(id === 2 ? page(2, [row(7, 'Pat Needs')]) : page(3, [], { program_type: 'household' })))
  api.resendAdminUserInvitation.mockResolvedValue({ user: {}, invitation_sent: true })
})
afterEach(cleanup)

describe('Today for a program owner', () => {
  it('opens on the group with someone who needs you, then invitations that went nowhere, then each group', async () => {
    render(<TodaySection currentUser={staff()} />)
    expect(await screen.findByText('Pat Needs')).toBeTruthy()
    expect(screen.getByText('Asked for help with an upload')).toBeTruthy()
    expect(screen.getByRole('button', { name: /^1\s*Need you/ }).getAttribute('aria-pressed')).toBe('true')
    const headings = screen.getAllByRole('heading', { level: 3 }).map(item => item.textContent)
    expect(headings).toEqual(['Bank of Guam 90 day savings', 'Invitations to follow up', 'Your groups'])
    expect(screen.getByText('Bea Bounced')).toBeTruthy()
    expect(screen.queryByText('Joined Jo')).toBeNull()
    expect(screen.getByText(/4 checked in today · 1 need you/)).toBeTruthy()
  })

  it('lists a bounced invitation before one never accepted, with one action each', async () => {
    render(<TodaySection currentUser={staff()} />)
    await screen.findByText('Bea Bounced')
    const names = screen.getAllByRole('button', { name: 'Send again' })
    expect(names).toHaveLength(2)
    fireEvent.click(names[0])
    await waitFor(() => expect(api.resendAdminUserInvitation).toHaveBeenCalledWith(2))
    expect(await screen.findByText(/Invitation sent again to/)).toBeTruthy()
  })

  it('shows the first five invitations to follow up and sends the rest to People', async () => {
    api.fetchAdminUsers.mockResolvedValue(Array.from({ length: 8 }, (_, index) => person(40 + index, `Invitee ${index}`, { invitation_status: 'pending', can_resend_invitation: true })))
    render(<TodaySection currentUser={staff()} />)
    await screen.findByText('Invitee 0')
    expect(screen.getAllByRole('button', { name: 'Send again' })).toHaveLength(5)
    expect(screen.getByRole('button', { name: 'See all 8 in People' })).toBeTruthy()
  })

  it('never lists a cancelled invitee, and never ends a line with a separator', async () => {
    api.fetchAdminUsers.mockResolvedValue([
      person(60, 'Cancelled Cal', { invitation_status: 'revoked', cohorts: [] }),
      person(61, 'Empty Em', { invitation_status: 'pending', cohorts: [] }),
      person(62, 'Real Ro', { invitation_status: 'pending', can_resend_invitation: true }),
    ])
    render(<TodaySection currentUser={staff()} />)
    await screen.findByText('Real Ro')
    expect(screen.queryByText('Cancelled Cal')).toBeNull()
    expect(screen.queryByText('Empty Em')).toBeNull()
    expect(document.body.textContent).not.toMatch(/ · $|· \s*$/m)
  })

  it('opens a person who needs you to the request and what they chose to share', async () => {
    render(<TodaySection currentUser={staff()} />)
    fireEvent.click(await screen.findByRole('button', { name: 'View help for Pat Needs' }))
    expect(await screen.findByText('Setup request details')).toBeTruthy()
  })

  it('never says nobody needs you when it could not read the people', async () => {
    daily.daily.mockRejectedValue(new ApiRequestError('Not allowed', { status: 403 }))
    render(<TodaySection currentUser={adminUser()} />)
    expect(await screen.findByText(/only in the groups you coach/)).toBeTruthy()
    expect(screen.queryByText('No one has asked for help.')).toBeNull()
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('keeps a timeout or server error apart from "not your group": it says so and offers another try', async () => {
    daily.daily.mockRejectedValueOnce(new ApiRequestError('Server error', { status: 503 })).mockRejectedValueOnce(new ApiRequestError('Server error', { status: 503 }))
    render(<TodaySection currentUser={adminUser()} />)
    const alert = await screen.findByRole('alert')
    expect(alert.textContent).toContain('We couldn’t load the people in')
    expect(screen.queryByText(/only in the groups you coach/)).toBeNull()
    daily.daily.mockImplementation((id: number) => Promise.resolve(id === 2 ? page(2, [row(7, 'Pat Needs')]) : page(3, [], { program_type: 'household' })))
    fireEvent.click(within(alert).getByRole('button', { name: 'Try again' }))
    expect(await screen.findByText('Pat Needs')).toBeTruthy()
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('gives the setup inbox the shared lifecycle, so the program picker locks while a request is changed from here', async () => {
    render(<TodaySection currentUser={staff()} />)
    fireEvent.click(await screen.findByRole('button', { name: 'View help for Pat Needs' }))
    await screen.findByText('Setup request details')
    expect(inbox.props?.mutationLifecycle).toBeTruthy()
  })

  it('says so plainly when no one has asked', async () => {
    daily.daily.mockImplementation((id: number, _search: string, filter: string) => Promise.resolve(page(id, filter === 'needs_help' ? [] : [quiet(8, 'Quiet Quin')], { counts: counts({ all: 1 }) })))
    render(<TodaySection currentUser={staff()} />)
    expect(await screen.findByText('Quiet Quin')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: /^0\s*Need you/ }))
    expect(await screen.findByText('No one has asked for help.')).toBeTruthy()
  })
})

describe('the daily list', () => {
  const everyone = [row(7, 'Pat Needs'), quiet(8, 'Quiet Quin'), quiet(9, 'Calm Cal')]
  beforeEach(() => {
    daily.daily.mockImplementation((id: number, search: string, filter: string, offset: number) => {
      if (id !== 2) return Promise.resolve(page(3, [], { program_type: 'household' }))
      const shown = everyone.filter(item => (filter === 'all' || filter === 'not_checked_in' || item.needs_help) && item.participant.name.toLowerCase().includes(search.toLowerCase()))
      return Promise.resolve(page(2, shown, { counts: counts({ all: 3, needs_help: 1, not_checked_in: 3 }), next_offset: null, offset }))
    })
  })

  it('has the four filters with the server’s counts, and “No check-in today” lists who has not checked in', async () => {
    render(<TodaySection currentUser={staff()} />)
    await screen.findByText('Pat Needs')
    const chips = within(screen.getByRole('group', { name: 'Show people who' }))
    expect(chips.getAllByRole('button').map(item => item.textContent)).toEqual(['3 Everyone', '1 Need you', '4 Checked in', '3 No check-in today'])
    fireEvent.click(chips.getByRole('button', { name: /No check-in today/ }))
    expect(await screen.findByText('Quiet Quin')).toBeTruthy()
    expect(daily.daily).toHaveBeenCalledWith(2, '', 'not_checked_in', 0, expect.anything())
    expect(screen.getAllByRole('button', { name: /^View / })).toHaveLength(3)
  })

  it('finds a person by name', async () => {
    render(<TodaySection currentUser={staff()} />)
    await screen.findByText('Pat Needs')
    fireEvent.click(screen.getByRole('button', { name: /Everyone/ }))
    await screen.findByText('Calm Cal')
    fireEvent.change(screen.getByLabelText('Find someone'), { target: { value: 'quin' } })
    await waitFor(() => expect(screen.queryByText('Calm Cal')).toBeNull())
    expect(screen.getByText('Quiet Quin')).toBeTruthy()
    expect(daily.daily).toHaveBeenCalledWith(2, 'quin', 'all', 0, expect.anything())
  })

  it('pages with Show more and never drops anyone, and the count says how many are left', async () => {
    const twenty = Array.from({ length: 20 }, (_, index) => quiet(100 + index, `Person ${String(index).padStart(2, '0')}`))
    const rest = Array.from({ length: 5 }, (_, index) => quiet(200 + index, `Later ${index}`))
    daily.daily.mockImplementation((id: number, _search: string, filter: string, offset: number) => {
      if (id !== 2) return Promise.resolve(page(3, [], { program_type: 'household' }))
      const records = offset === 0 ? (filter === 'needs_help' ? [row(7, 'Pat Needs')] : twenty) : rest
      return Promise.resolve(page(2, records, { counts: counts({ all: 25, needs_help: 1, not_checked_in: 25 }), total: filter === 'all' ? 25 : 1, next_offset: offset === 0 && filter === 'all' ? 20 : null }))
    })
    render(<TodaySection currentUser={staff()} />)
    await screen.findByText('Pat Needs')
    fireEvent.click(screen.getByRole('button', { name: /Everyone/ }))
    await screen.findByText('Person 19')
    fireEvent.click(screen.getByRole('button', { name: 'Show more (5 left)' }))
    expect(await screen.findByText('Later 4')).toBeTruthy()
    expect(screen.getAllByRole('button', { name: /^View / })).toHaveLength(25)
    expect(screen.queryByRole('button', { name: /Show more/ })).toBeNull()
    expect(daily.daily).toHaveBeenCalledWith(2, '', 'all', 20, expect.anything())
  })

  it('counts what is left from the people who match the search, not from everyone', async () => {
    const twenty = Array.from({ length: 20 }, (_, index) => quiet(300 + index, `Ana ${String(index).padStart(2, '0')}`))
    daily.daily.mockImplementation((id: number, search: string, filter: string) => {
      if (id !== 2) return Promise.resolve(page(3, [], { program_type: 'household' }))
      if (!search && filter === 'needs_help') return Promise.resolve(page(2, [row(7, 'Pat Needs')]))
      return Promise.resolve(page(2, twenty, { counts: counts({ all: 60, needs_help: 1 }), total: 23, next_offset: 20 }))
    })
    render(<TodaySection currentUser={staff()} />)
    await screen.findByText('Pat Needs')
    fireEvent.change(screen.getByLabelText('Find someone'), { target: { value: 'ana' } })
    expect(await screen.findByRole('button', { name: 'Show more (3 left)' })).toBeTruthy()
  })

  it('offers View person for anyone on the list, not only people who asked for help', async () => {
    render(<TodaySection currentUser={staff()} />)
    await screen.findByText('Pat Needs')
    fireEvent.click(screen.getByRole('button', { name: /Everyone/ }))
    fireEvent.click(await screen.findByRole('button', { name: 'View Quiet Quin' }))
    expect(await screen.findByText('Shared items')).toBeTruthy()
  })

  it('shows a failed read with a way to try again', async () => {
    render(<TodaySection currentUser={staff()} />)
    await screen.findByText('Pat Needs')
    daily.daily.mockRejectedValueOnce(new Error('The list timed out.'))
    fireEvent.click(screen.getByRole('button', { name: /Everyone/ }))
    expect((await screen.findByRole('alert')).textContent).toContain('The list timed out.')
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(await screen.findByText('Quiet Quin')).toBeTruthy()
  })

  it('reads a few groups at a time and updates the screen once', async () => {
    const many = Array.from({ length: 9 }, (_, index) => group(10 + index, `Group ${index}`, { status: 'active' }))
    api.fetchAdminCohorts.mockResolvedValue(many)
    let inFlight = 0; let peak = 0
    daily.daily.mockImplementation((id: number) => { inFlight += 1; peak = Math.max(peak, inFlight); return new Promise(resolve => setTimeout(() => { inFlight -= 1; resolve(page(id, [], { program_type: 'household' })) }, 5)) })
    render(<TodaySection currentUser={staff()} />)
    await waitFor(() => expect(screen.getByLabelText('Group')).toBeTruthy())
    expect(peak).toBeLessThanOrEqual(4)
    expect(daily.daily).toHaveBeenCalledTimes(9)
  })
})

describe('Today for people below program owner', () => {
  for (const [name, user] of [['an editor', editorUser()], ['a reviewer', reviewerUser()]] as const) {
    it(`works for ${name}: reads only what that role may, with no permission banner and no owner-only actions`, async () => {
      render(<TodaySection currentUser={user} />)
      expect(await screen.findByText('Pat Needs')).toBeTruthy()
      expect(api.fetchAdminCohorts).not.toHaveBeenCalled()
      expect(api.fetchAdminUsers).not.toHaveBeenCalled()
      expect(api.fetchAdminPersonaAssignableCohorts).toHaveBeenCalled()
      expect(screen.queryByRole('alert')).toBeNull()
      expect(screen.queryByRole('button', { name: 'Invite people' })).toBeNull()
      expect(screen.queryByRole('button', { name: 'Create a group' })).toBeNull()
      expect(screen.queryByText('Invitations to follow up')).toBeNull()
      expect(screen.getByRole('button', { name: /^1\s*Need you/ })).toBeTruthy()
      // The groups they coach are listed as plain rows: there is no Groups section for them to open.
      expect(document.querySelectorAll('.admin-list-static')).toHaveLength(2)
    })
  }

  it('says what to do when they are on no group’s team, and offers no Create a group', async () => {
    api.fetchAdminPersonaAssignableCohorts.mockResolvedValue([])
    render(<TodaySection currentUser={editorUser()} />)
    expect(await screen.findByText(/aren’t on a group’s team yet/)).toBeTruthy()
    expect(screen.queryByRole('button', { name: 'Create a group' })).toBeNull()
  })

  it('offers Create a group only to someone who can manage groups', async () => {
    api.fetchAdminCohorts.mockResolvedValue([])
    render(<TodaySection currentUser={staff()} />)
    expect(await screen.findByRole('button', { name: 'Create a group' })).toBeTruthy()
  })
})

describe('Invite people from Today', () => {
  it('never preselects a group when there is more than one, and names the group before sending', async () => {
    api.createAdminUser.mockResolvedValue({ user: {}, invitation_sent: true, invitation_status: 'sent' })
    const asked: ConfirmRequest[] = []
    const unregister = registerConfirmHost(request => { asked.push(request); request.resolve(true) })
    render(<TodaySection currentUser={staff()} />)
    fireEvent.click(await screen.findByRole('button', { name: 'Invite people' }))
    const dialog = within(await screen.findByRole('dialog'))
    expect((dialog.getByLabelText('Group') as HTMLSelectElement).value).toBe('')
    fireEvent.change(dialog.getByLabelText(/Email addresses/), { target: { value: 'a@x.test, b@x.test, c@x.test' } })
    fireEvent.click(dialog.getByRole('button', { name: 'Invite 3 people' }))
    expect(await screen.findByText('Choose which group they are joining.')).toBeTruthy()
    expect(api.createAdminUser).not.toHaveBeenCalled()
    fireEvent.change(dialog.getByLabelText('Group'), { target: { value: '2' } })
    fireEvent.click(dialog.getByRole('button', { name: 'Invite 3 people' }))
    await waitFor(() => expect(api.createAdminUser).toHaveBeenCalledTimes(3))
    expect(asked.map(request => request.title)).toEqual(['Invite 3 people to Bank of Guam 90 day savings?'])
    unregister()
  })
})
