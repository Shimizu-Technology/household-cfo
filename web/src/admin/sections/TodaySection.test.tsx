// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { adminUser, group, person, savings, staff } from '../../test/adminFixtures'

const api = vi.hoisted(() => ({ fetchAdminCohorts: vi.fn(), fetchAdminUsers: vi.fn(), resendAdminUserInvitation: vi.fn(), createAdminUser: vi.fn() }))
vi.mock('../../api', async original => ({ ...await original<typeof import('../../api')>(), ...api }))
const daily = vi.hoisted(() => ({ daily: vi.fn() }))
vi.mock('../../lib/coachChallengeApi', async original => ({ ...await original<typeof import('../../lib/coachChallengeApi')>(), coachChallengeApi: { daily: daily.daily } }))
vi.mock('../../contexts/authContextValue', () => ({ useAuthContext: () => ({ activeCoachWorkspaceId: 5, selectCoachWorkspace: vi.fn() }) }))
vi.mock('../../components/SetupSupportInbox', () => ({ SetupSupportInbox: () => <p>Setup request details</p> }))
vi.mock('../../components/ParticipantHelp', () => ({ ParticipantHelp: () => <p>Shared items</p> }))
import { TodaySection } from './TodaySection'

const bog = group(2, 'Bank of Guam 90 day savings', { savings_challenge: savings('open') })
const household = group(3, 'Mel’s Household Group', { status: 'active' })
const row = (id: number, name: string, over = {}) => ({ participant: { id, name }, needs_help: true, setup_help: [{ id: 1, reason: 'upload_problem', status: 'requested' }], help_requests: [], shared_items: [], enrollment_id: null, check_in: null, ...over })
const page = (id: number, records: unknown[], counts = {}) => ({ cohort_id: id, counts: { checked_in: 4, needs_help: records.length, ...counts }, records, next_offset: null })
beforeEach(() => {
  vi.resetAllMocks()
  api.fetchAdminCohorts.mockResolvedValue([bog, household])
  api.fetchAdminUsers.mockResolvedValue([
    person(1, 'Nora Never', { invitation_status: 'pending', can_resend_invitation: true, cohorts: [{ id: 5, role: 'participant', cohort: { id: 2, name: bog.name, status: 'enrolling' } }] }),
    person(2, 'Bea Bounced', { invitation_status: 'pending', invite_email: { status: 'failed' }, can_resend_invitation: true }),
    person(3, 'Joined Jo'),
  ])
  daily.daily.mockImplementation((id: number) => Promise.resolve(id === 2 ? page(2, [row(7, 'Pat Needs')]) : page(3, [])))
  api.resendAdminUserInvitation.mockResolvedValue({ user: {}, invitation_sent: true })
})
afterEach(cleanup)

describe('Today', () => {
  it('puts who needs you first, then invitations that went nowhere, then each group', async () => {
    render(<TodaySection currentUser={staff()} />)
    expect(await screen.findByText('Pat Needs')).toBeTruthy()
    expect(screen.getByText('Asked for help with an upload')).toBeTruthy()
    const headings = screen.getAllByRole('heading', { level: 3 }).map(item => item.textContent)
    expect(headings).toEqual(['Needs you', 'Invitations to follow up', 'Your groups'])
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
  it('opens a person who needs you to the request and what they chose to share', async () => {
    render(<TodaySection currentUser={staff()} />)
    fireEvent.click(await screen.findByRole('button', { name: /Pat Needs/ }))
    expect(await screen.findByText('Setup request details')).toBeTruthy()
  })
  it('never says nobody needs you when it could not read the people', async () => {
    daily.daily.mockRejectedValue(new Error('forbidden'))
    render(<TodaySection currentUser={adminUser()} />)
    expect(await screen.findByText(/only for the groups you coach/)).toBeTruthy()
    expect(screen.queryByText('No one has asked for help.')).toBeNull()
  })
  it('says so plainly when no one has asked', async () => {
    daily.daily.mockImplementation((id: number) => Promise.resolve(page(id, [])))
    render(<TodaySection currentUser={staff()} />)
    expect(await screen.findByText('No one has asked for help.')).toBeTruthy()
  })
})
