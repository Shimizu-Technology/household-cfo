// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { CoachChallengeDashboard } from './CoachChallengeDashboard'
import { coachChallengeApi } from '../lib/coachChallengeApi'
import { ApiRequestError } from '../api'
vi.mock('../lib/coachChallengeApi', () => ({
  coachChallengeApi: {
    participants: vi.fn(),
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
  participant: { id: 3, name: 'Synthetic participant' },
  participation_status: 'active',
  setup_status: 'plan_reviewed',
  check_in: { local_on: '2026-11-01', completed: true, availability: 'available' },
  help_requests: [],
  more_help_requests: false,
}
const props = { userId: 10, workspaceId: 20, cohorts: [{ id: 1, name: 'Synthetic cohort' }] }
beforeEach(() => {
  vi.clearAllMocks()
  vi.mocked(coachChallengeApi.participants).mockResolvedValue({
    actor_scope: scope,
    cohort_id: 1,
    records: [row],
    next_cursor: null,
  })
})
async function open() {
  render(<CoachChallengeDashboard {...props} />)
  fireEvent.change(screen.getByLabelText('Challenge group'), { target: { value: '1' } })
  await screen.findByText('Synthetic participant')
  fireEvent.click(screen.getByRole('button', { name: 'Open permitted help & sharing' }))
}
describe('coach challenge permission boundaries', () => {
  it('pages thirty enrolled participants and searches the loaded roster without extra private reads', async () => {
    vi.mocked(coachChallengeApi.participants).mockResolvedValueOnce({ actor_scope: scope, cohort_id: 1, records: Array.from({ length: 30 }, (_, index) => ({ ...row, enrollment_id: index + 1, participant: { id: index + 40, name: `Fictional participant ${String(index).padStart(2, '0')}` } })), next_cursor: null })
    render(<CoachChallengeDashboard {...props} selectedCohortId={1} />)
    await screen.findByText('Fictional participant 00')
    expect(document.querySelectorAll('.coach-challenge-roster > li')).toHaveLength(10)
    expect(screen.queryByText('Fictional participant 29')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Next check-ins' }))
    expect(screen.getByText('Fictional participant 10')).toBeTruthy()
    fireEvent.change(screen.getByLabelText('Find an enrolled participant'), { target: { value: 'participant 29' } })
    expect(screen.getByText('Fictional participant 29')).toBeTruthy()
    expect(document.querySelectorAll('.coach-challenge-roster > li')).toHaveLength(1)
    expect(coachChallengeApi.participants).toHaveBeenCalledTimes(1)
    expect(coachChallengeApi.summary).not.toHaveBeenCalled()
    expect(coachChallengeApi.ticket).not.toHaveBeenCalled()
  })

  it('uses the single selected cohort and searches participation without revealing money', async () => {
    const view = render(<CoachChallengeDashboard {...props} selectedCohortId={1} />)
    await screen.findByText('Synthetic participant')
    expect(screen.queryByLabelText('Challenge group')).toBeNull()
    expect(screen.queryByRole('button', { name: 'Previous participants' })).toBeNull()
    fireEvent.change(screen.getByLabelText('Find an enrolled participant'), { target: { value: 'another name' } })
    expect(screen.queryByText('Synthetic participant')).toBeNull()
    expect(coachChallengeApi.summary).not.toHaveBeenCalled()
    vi.mocked(coachChallengeApi.participants).mockResolvedValueOnce({ actor_scope: scope, cohort_id: 9, records: [], next_cursor: null })
    view.rerender(<CoachChallengeDashboard {...props} cohorts={[{ id: 9, name: 'Another challenge' }]} selectedCohortId={9} />)
    expect(screen.queryByText('Synthetic participant')).toBeNull()
    await waitFor(() => expect(coachChallengeApi.participants).toHaveBeenLastCalledWith(9, null, expect.any(AbortSignal)))
    await screen.findByText(/No enrolled participants on this page/)
  })

  it('keeps exactly one participant panel when enrollment and cohort IDs coincide', async () => {
    vi.mocked(coachChallengeApi.participants).mockResolvedValue({
      actor_scope: scope, cohort_id: 1, records: [{ ...row, enrollment_id: 1 }], next_cursor: null,
    })
    await open()
    expect(screen.getAllByRole('region', { name: 'Participant permitted sharing' })).toHaveLength(1)
    fireEvent.click(screen.getByRole('button', { name: 'Close participant' }))
    expect(screen.queryByRole('region', { name: 'Participant permitted sharing' })).toBeNull()
    expect(screen.getAllByText('Fixed cohort checkpoint reports')).toHaveLength(1)
    fireEvent.click(screen.getByRole('button', { name: 'Open permitted help & sharing' }))
    expect(screen.getAllByRole('region', { name: 'Participant permitted sharing' })).toHaveLength(1)
    fireEvent.click(screen.getByRole('button', { name: 'Close participant' }))
    expect(screen.queryByRole('region', { name: 'Participant permitted sharing' })).toBeNull()
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
    fireEvent.click(screen.getByRole('button', { name: 'Check current sharing permissions' }))
    await screen.findByText('Challenge summary shared')
    expect(coachChallengeApi.summary).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Open consented savings summary' }))
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
    fireEvent.click(screen.getByRole('button', { name: 'Check current sharing permissions' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Open consented savings summary' }))
    await screen.findByText(/\$100.00 reported/)
    fireEvent.click(screen.getByRole('button', { name: 'Check current sharing permissions' }))
    await screen.findByText('Sharing revoked')
    expect(screen.queryByText(/\$100.00 reported/)).toBeNull()
  })
  it('rejects a different workspace response without participant metadata', async () => {
    vi.mocked(coachChallengeApi.participants).mockResolvedValue({
      actor_scope: { ...scope, coach_workspace_id: 99 },
      cohort_id: 1,
      records: [row],
      next_cursor: null,
    })
    render(<CoachChallengeDashboard {...props} />)
    fireEvent.change(screen.getByLabelText('Challenge group'), { target: { value: '1' } })
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
    fireEvent.change(screen.getByLabelText('Challenge group'), { target: { value: '1' } })
    await screen.findByText('Synthetic participant')
    fireEvent.click(screen.getByRole('button', { name: 'Open permitted help & sharing' }))
    fireEvent.click(screen.getByRole('button', { name: 'Check current sharing permissions' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Open consented savings summary' }))
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
