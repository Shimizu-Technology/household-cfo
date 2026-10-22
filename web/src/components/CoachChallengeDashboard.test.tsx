// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { CoachChallengeDashboard } from './CoachChallengeDashboard'
import { coachChallengeApi } from '../lib/coachChallengeApi'
import { ApiRequestError } from '../api'
vi.mock('../lib/coachChallengeApi', () => ({
  coachChallengeApi: {
    participants: vi.fn(),
    daily: vi.fn(),
    scopes: vi.fn(),
    summary: vi.fn(),
    selected: vi.fn(),
    exports: vi.fn(),
    ticket: vi.fn(),
    ticketStatus: vi.fn(),
    help: vi.fn(),
    seal: vi.fn(),
    report: vi.fn(),
  },
}))
afterEach(cleanup)
const scope = { user_id: 10, coach_workspace_id: 20 }
const row = {
  enrollment_id: 2,
  membership_status: 'joined' as const, needs_help: false, setup_help: [], shared_items: [],
  participant: { id: 3, name: 'Synthetic participant' },
  participation_status: 'active',
  setup_status: 'plan_reviewed',
  check_in: { local_on: '2026-11-01', completed: true, availability: 'available' },
  help_requests: [],
  more_help_requests: false,
}
const props = { userId: 10, workspaceId: 20, cohorts: [{ id: 1, name: 'Synthetic cohort' }] }
beforeEach(() => {
  vi.resetAllMocks()
  vi.mocked(coachChallengeApi.daily).mockResolvedValue({
    actor_scope: scope,
    cohort_id: 1,
    records: [row],
    program_type: 'savings', can_invite: false, counts: { all: 1, needs_help: 0, checked_in: 1, not_checked_in: 0, invited: 0, joined: 1, setup_done: 0 }, next_offset: null,
  })
  vi.mocked(coachChallengeApi.scopes).mockResolvedValue({ enrollment_id: 2, summary_available: false, selected_records: [], support_access: [] })
  vi.stubGlobal('matchMedia', () => ({ matches: false }))
  vi.spyOn(window, 'scrollTo').mockImplementation(() => {})
})
async function open() {
  render(<CoachChallengeDashboard {...props} />)
  fireEvent.change(screen.getByLabelText('Group'), { target: { value: '1' } })
  await screen.findByText('Synthetic participant')
  fireEvent.click(screen.getByRole('button', { name: 'View Synthetic participant' }))
}
describe('coach challenge permission boundaries', () => {
  it('puts the people before secondary invitation and refresh actions', async () => {
    vi.mocked(coachChallengeApi.daily).mockResolvedValueOnce({
      actor_scope: scope, cohort_id: 1, records: [row], program_type: 'savings', can_invite: true,
      counts: { all: 1, needs_help: 0, checked_in: 1, not_checked_in: 0, invited: 0, joined: 1, setup_done: 0 }, next_offset: null,
    })
    render(<CoachChallengeDashboard {...props} selectedCohortId={1} />)
    const person = await screen.findByText('Synthetic participant')
    const invite = screen.getByRole('button', { name: 'Invite someone' })
    const refresh = screen.getByRole('button', { name: 'Refresh' })
    expect(person.compareDocumentPosition(invite) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(person.compareDocumentPosition(refresh) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })
  it('shows each daily check-in with a plain date and plain status', async () => {
    render(<CoachChallengeDashboard {...props} selectedCohortId={1} />)
    await screen.findByText('Synthetic participant')
    const roster = document.querySelector('.coach-challenge-roster')!.textContent!
    expect(roster).toContain('Checked in today')
    expect(roster).not.toMatch(/\d{4}-\d{2}-\d{2}/)
    expect(roster).not.toContain('Daily report completed')
  })
  it('keeps the roster available when its active count is tapped again', async () => {
    render(<CoachChallengeDashboard {...props} selectedCohortId={1} />)
    await screen.findByText('Synthetic participant')
    fireEvent.click(screen.getByRole('button', { name: '1 Everyone' }))
    expect(screen.getByText('Synthetic participant')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Refresh' })).toHaveProperty('disabled', false)
    expect(coachChallengeApi.daily).toHaveBeenCalledTimes(1)
  })
  it('searches and filters on the server without fetching private records', async () => {
    render(<CoachChallengeDashboard {...props} selectedCohortId={1} />)
    await screen.findByText('Synthetic participant')
    vi.mocked(coachChallengeApi.daily).mockResolvedValueOnce({ actor_scope: scope, cohort_id: 1, records: [], program_type: 'savings', can_invite: false, counts: { all: 30, needs_help: 1, checked_in: 2, not_checked_in: 28, invited: 0, joined: 30, setup_done: 0 }, next_offset: null })
    fireEvent.change(screen.getByLabelText('Find someone'), { target: { value: 'person beyond first page' } })
    await screen.findByText(/No one matches/)
    expect(coachChallengeApi.daily).toHaveBeenLastCalledWith(1, 'person beyond first page', 'all', 0, expect.any(AbortSignal))
    fireEvent.click(screen.getByRole('button', { name: '1 Need you' }))
    await waitFor(() => expect(coachChallengeApi.daily).toHaveBeenLastCalledWith(1, 'person beyond first page', 'needs_help', 0, expect.any(AbortSignal)))
    expect(coachChallengeApi.summary).not.toHaveBeenCalled()
    expect(coachChallengeApi.ticket).not.toHaveBeenCalled()
  })

  it('keeps exactly one participant panel when enrollment and cohort IDs coincide', async () => {
    vi.mocked(coachChallengeApi.daily).mockResolvedValue({
      actor_scope: scope, cohort_id: 1, records: [{ ...row, enrollment_id: 1 }], program_type: 'savings', can_invite: false, counts: { all: 1, needs_help: 0, checked_in: 1, not_checked_in: 0, invited: 0, joined: 1, setup_done: 0 }, next_offset: null,
    })
    await open()
    expect(screen.getAllByRole('region', { name: 'Participant permitted sharing' })).toHaveLength(1)
    fireEvent.click(screen.getByRole('button', { name: 'Back to people' }))
    expect(screen.queryByRole('region', { name: 'Participant permitted sharing' })).toBeNull()
    expect(screen.getAllByText('Group checkpoint reports')).toHaveLength(1)
    fireEvent.click(screen.getByRole('button', { name: 'View Synthetic participant' }))
    expect(screen.getAllByRole('region', { name: 'Participant permitted sharing' })).toHaveLength(1)
    fireEvent.click(screen.getByRole('button', { name: 'Back to people' }))
    expect(screen.queryByRole('region', { name: 'Participant permitted sharing' })).toBeNull()
  })

  it('shows household people and their setup needs without savings or empty enrollment wording', async () => {
    vi.mocked(coachChallengeApi.daily).mockResolvedValue({ actor_scope: scope, cohort_id: 1, program_type: 'household', can_invite: true,
      counts: { all: 2, needs_help: 1, invited: 1, joined: 1, setup_done: 0, checked_in: 0, not_checked_in: 0 }, next_offset: null,
      records: [{ ...row, enrollment_id: null, check_in: null, needs_help: true, participant: { id: 7, name: 'Elena' }, setup_help: [{ id: 8, reason: 'upload_problem', status: 'requested' }] },
        { ...row, enrollment_id: null, check_in: null, membership_status: 'invited', participant: { id: 8, name: 'Fiona' } }] })
    render(<CoachChallengeDashboard {...props} selectedCohortId={1} />)
    await screen.findByText('Elena')
    expect(screen.getByText('Asked for help with an upload')).toBeTruthy()
    expect(screen.getByText('Invited · Hasn’t joined yet')).toBeTruthy()
    expect(screen.queryByText('Checkpoint reports')).toBeNull()
    expect(screen.queryByText(/No enrolled|check-in|Challenge check-ins/)).toBeNull()
    expect(screen.getByRole('button', { name: 'Invite someone' })).toBeTruthy()
  })

  it('opens focused detail and restores the same selected row on Back', async () => {
    await open()
    expect(screen.getByRole('heading', { name: 'Synthetic participant' })).toBe(document.activeElement)
    fireEvent.click(screen.getByRole('button', { name: 'Back to people' }))
    expect(screen.getByRole('button', { name: 'View Synthetic participant' })).toBe(document.activeElement)
    expect(window.scrollTo).toHaveBeenCalledWith({ top: 0, behavior: 'instant' })
  })

  it('does not move focus back to the roster when an invitation refreshes it', async () => {
    await open()
    const input = document.createElement('input')
    document.body.append(input); input.focus()
    act(() => window.dispatchEvent(new CustomEvent('coach-roster-changed', { detail: 1 })))
    expect(document.activeElement).toBe(input)
    expect(window.scrollTo).not.toHaveBeenCalled()
    input.remove()
  })

  it('loads only metadata until separate explicit consented summary read', async () => {
    vi.mocked(coachChallengeApi.scopes).mockResolvedValue({
      enrollment_id: 2,
      summary_available: true,
      selected_records: [],
      support_access: [],
    })
    vi.mocked(coachChallengeApi.summary).mockResolvedValue({
      enrollment_id: 2,
      accepted_target_cents: 50000,
      projection: { reported_cents: 10000, evidence_supported_cents: 5000, reporting_known: true, achieved: false },
    })
    await open()
    expect(coachChallengeApi.summary).not.toHaveBeenCalled()
    await screen.findByText('Challenge summary shared')
    expect(coachChallengeApi.summary).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'View shared progress' }))
    await screen.findByText(/\$100.00 reported/)
    expect(coachChallengeApi.summary).toHaveBeenCalledTimes(1)
  })
  it('clears previously displayed money when current permissions fail', async () => {
    vi.mocked(coachChallengeApi.scopes)
      .mockResolvedValueOnce({ enrollment_id: 2, summary_available: true, selected_records: [], support_access: [] })
      .mockRejectedValue(new ApiRequestError('Sharing revoked', { status: 403 }))
    vi.mocked(coachChallengeApi.summary).mockResolvedValue({
      enrollment_id: 2,
      accepted_target_cents: 50000,
      projection: { reported_cents: 10000, evidence_supported_cents: 5000, reporting_known: true, achieved: false },
    })
    await open()
    const progress = await screen.findByRole('button', { name: 'View shared progress' })
    await waitFor(() => expect(progress).toHaveProperty('disabled', false))
    fireEvent.click(progress)
    await screen.findByText(/\$100.00 reported/)
    fireEvent.click(screen.getByRole('button', { name: 'Refresh shared items' }))
    await screen.findByText('Sharing revoked')
    expect(screen.queryByText(/\$100.00 reported/)).toBeNull()
  })
  it('clears an opened private summary when the main roster is refreshed', async () => {
    vi.mocked(coachChallengeApi.scopes).mockResolvedValue({ enrollment_id: 2, summary_available: true, selected_records: [], support_access: [] })
    vi.mocked(coachChallengeApi.summary).mockResolvedValue({ enrollment_id: 2, accepted_target_cents: 50000, projection: { reported_cents: 10000, evidence_supported_cents: 0, reporting_known: true, achieved: false } })
    await open()
    fireEvent.click(await screen.findByRole('button', { name: 'View shared progress' }))
    await screen.findByText(/\$100.00 reported/)
    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }))
    expect(screen.queryByText(/\$100.00 reported/)).toBeNull()
    expect(screen.queryByRole('region', { name: 'Participant permitted sharing' })).toBeNull()
  })
  it('rejects a different workspace response without participant metadata', async () => {
    vi.mocked(coachChallengeApi.daily).mockResolvedValue({
      actor_scope: { ...scope, coach_workspace_id: 99 },
      cohort_id: 1,
      records: [row],
      program_type: 'savings', can_invite: false, counts: { all: 1, needs_help: 0, checked_in: 1, not_checked_in: 0, invited: 0, joined: 1, setup_done: 0 }, next_offset: null,
    })
    render(<CoachChallengeDashboard {...props} />)
    fireEvent.change(screen.getByLabelText('Group'), { target: { value: '1' } })
    await screen.findByRole('alert')
    expect(screen.queryByText('Synthetic participant')).toBeNull()
  })
  it('late summary cannot cross a workspace switch', async () => {
    let finish!: (result: Awaited<ReturnType<typeof coachChallengeApi.summary>>) => void
    vi.mocked(coachChallengeApi.scopes).mockResolvedValue({
      enrollment_id: 2,
      summary_available: true,
      selected_records: [],
      support_access: [],
    })
    vi.mocked(coachChallengeApi.summary).mockImplementation(
      () =>
        new Promise((resolve) => {
          finish = resolve
        })
    )
    const view = render(<CoachChallengeDashboard {...props} />)
    fireEvent.change(screen.getByLabelText('Group'), { target: { value: '1' } })
    await screen.findByText('Synthetic participant')
    fireEvent.click(screen.getByRole('button', { name: 'View Synthetic participant' }))
    const progress = await screen.findByRole('button', { name: 'View shared progress' })
    await waitFor(() => expect(progress).toHaveProperty('disabled', false))
    fireEvent.click(progress)
    await waitFor(() => expect(coachChallengeApi.summary).toHaveBeenCalled())
    view.rerender(<CoachChallengeDashboard {...props} workspaceId={21} />)
    await act(async () =>
      finish({
        enrollment_id: 2,
        accepted_target_cents: 50000,
        projection: { reported_cents: 98765, evidence_supported_cents: 0, reporting_known: true, achieved: true },
      })
    )
    expect(screen.queryByText(/987.65/)).toBeNull()
  })
})

describe('sealing a checkpoint report explains why it is unavailable', () => {
  async function openReports(cutoffOn: string | null, server: { sealable?: boolean; today_on?: string } = {}) {
    vi.mocked(coachChallengeApi.exports).mockResolvedValue({
      actor_scope: scope, cohort_id: 1, next_cursor: null, records: [], today_on: server.today_on,
      scheduled_checkpoints: [{ day: 30, cutoff_on: cutoffOn, sealable: server.sealable }, { day: 60, cutoff_on: null }, { day: 90, cutoff_on: null }],
    })
    render(<CoachChallengeDashboard {...props} />)
    fireEvent.change(screen.getByLabelText('Group'), { target: { value: '1' } })
    await screen.findByText('Synthetic participant')
    fireEvent.click(screen.getByText('Review scheduled reports'))
    return screen.findByText('Save reviewed Day 30 report')
  }

  it('says the cutoff has not happened yet and links the reason to the button', async () => {
    const button = await openReports('2999-11-14')
    expect(button).toHaveProperty('disabled', true)
    const reason = document.getElementById(button.getAttribute('aria-describedby') ?? '')
    expect(reason?.textContent).toContain('Nov 14, 2999')
    expect(reason?.textContent).toContain('hasn’t ended yet')
  })

  it('trusts the server on the cutoff day itself, whatever this browser clock says', async () => {
    const button = await openReports('2999-11-15', { sealable: true, today_on: '2999-11-15' })
    expect(document.getElementById(button.getAttribute('aria-describedby') ?? '')?.textContent).toContain('Tick the box')
  })

  it('says the cutoff has not ended when the server says it cannot be sealed yet', async () => {
    const button = await openReports('2000-01-30', { sealable: false, today_on: '2000-01-29' })
    expect(document.getElementById(button.getAttribute('aria-describedby') ?? '')?.textContent).toContain('hasn’t ended yet')
  })

  it('asks for the review confirmation once the cutoff has passed', async () => {
    const button = await openReports('2000-01-30')
    expect(button).toHaveProperty('disabled', true)
    expect(document.getElementById(button.getAttribute('aria-describedby') ?? '')?.textContent).toContain('Tick the box')
    fireEvent.click(screen.getByRole('checkbox'))
    expect(button).toHaveProperty('disabled', false)
    expect(button.getAttribute('aria-describedby')).toBeNull()
  })
})
