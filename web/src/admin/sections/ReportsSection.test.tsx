// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError } from '../../api'
import { adminUser, group, reviewerUser, savings } from '../../test/adminFixtures'

const api = vi.hoisted(() => ({ fetchAdminCohorts: vi.fn(), fetchAdminUsers: vi.fn(), fetchAdminPersonaAssignableCohorts: vi.fn() }))
vi.mock('../../api', async original => ({ ...await original<typeof import('../../api')>(), ...api }))
const reports = vi.hoisted(() => ({ exports: vi.fn(), seal: vi.fn(), report: vi.fn() }))
vi.mock('../../lib/coachChallengeApi', async original => ({ ...await original<typeof import('../../lib/coachChallengeApi')>(), coachChallengeApi: reports }))
import { ReportsSection } from './ReportsSection'

const bog = group(2, 'Bank of Guam 90 day savings', { savings_challenge: savings('open') })
const index = (over = {}) => ({ can_seal: true, scheduled_checkpoints: [{ day: 30, cutoff_on: '2026-11-09', sealable: true }, { day: 60, cutoff_on: '2026-12-09', sealable: false }, { day: 90, cutoff_on: null }], records: [], next_cursor: null, ...over })
const report = { checkpoint_day: 30, cutoff_on: '2026-11-09', active_consent_count_range: '5–9', bands: [{ band: 'on_track', count_range: '5–9' }], suppressed: false, qualification: '' }
beforeEach(() => {
  vi.resetAllMocks()
  api.fetchAdminCohorts.mockResolvedValue([bog, group(3, 'Household', { status: 'active' })]); api.fetchAdminUsers.mockResolvedValue([])
  reports.exports.mockResolvedValue(index()); reports.seal.mockResolvedValue({ export_id: 4, report }); reports.report.mockResolvedValue({ export_id: 4, report })
})
afterEach(cleanup)

describe('Reports', () => {
  it('shows Day 30, 60 and 90 for each savings group, with one action where there is one', async () => {
    render(<ReportsSection currentUser={adminUser()} />)
    const rows = await screen.findAllByText(/^Day (30|60|90)$/)
    expect(rows).toHaveLength(3)
    expect(reports.exports).toHaveBeenCalledTimes(1)
    expect(screen.getByText('Bank of Guam 90 day savings')).toBeTruthy()
    expect(screen.queryByText('Household')).toBeNull()
    expect(screen.getAllByRole('button', { name: 'Save the report' })).toHaveLength(1)
    expect(screen.getByText(/Not ready yet/)).toBeTruthy()
    expect(screen.getByText(/Needs a start date first/)).toBeTruthy()
    expect(screen.getByText(/never names or personal amounts/)).toBeTruthy()
  })
  it('saves a report only after the privacy box is ticked, then shows it', async () => {
    render(<ReportsSection currentUser={adminUser()} />)
    fireEvent.click(await screen.findByRole('button', { name: 'Save the report' }))
    const dialog = screen.getByRole('dialog')
    expect(within(dialog).getByRole('button', { name: 'Save the report' })).toHaveProperty('disabled', true)
    fireEvent.click(within(dialog).getByRole('checkbox'))
    fireEvent.click(within(dialog).getByRole('button', { name: 'Save the report' }))
    await waitFor(() => expect(reports.seal).toHaveBeenCalledWith(2, 30, expect.any(AbortSignal)))
    expect(await screen.findByText('5–9 people')).toBeTruthy()
  })
  it('explains a hidden report instead of showing numbers', async () => {
    reports.exports.mockResolvedValue(index({ records: [{ id: 4, checkpoint_day: 30, resolved_cutoff_on: '2026-11-09' }] }))
    reports.report.mockResolvedValue({ export_id: 4, report: { ...report, suppressed: true, bands: [] } })
    render(<ReportsSection currentUser={adminUser()} />)
    fireEvent.click(await screen.findByRole('button', { name: 'View report' }))
    expect(await screen.findByText(/Fewer than five people agreed to share/)).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Download this report' })).toBeTruthy()
  })
  it('offers no save to someone who may only read reports', async () => {
    reports.exports.mockResolvedValue(index({ can_seal: false }))
    render(<ReportsSection currentUser={adminUser()} />)
    await screen.findAllByText(/^Day (30|60|90)$/)
    expect(screen.queryByRole('button', { name: 'Save the report' })).toBeNull()
  })
  it('says who can save a report when this person cannot', async () => {
    reports.exports.mockResolvedValue(index({ can_seal: false }))
    render(<ReportsSection currentUser={adminUser()} />)
    await screen.findAllByText(/^Day (30|60|90)$/)
    expect(screen.getByText(/Only the coaches of this group can save it: a program owner or reviewer on its team/)).toBeTruthy()
  })
  it('works for a reviewer, who cannot list groups: finds the savings groups from the groups they may see', async () => {
    api.fetchAdminPersonaAssignableCohorts.mockResolvedValue([{ id: 2, name: bog.name, status: 'enrolling', savings_challenge_enabled: true }, { id: 3, name: 'Household', status: 'active', savings_challenge_enabled: false }])
    render(<ReportsSection currentUser={reviewerUser()} />)
    await screen.findAllByText(/^Day (30|60|90)$/)
    expect(api.fetchAdminCohorts).not.toHaveBeenCalled()
    expect(reports.exports).toHaveBeenCalledTimes(1)
    expect(screen.queryByRole('alert')).toBeNull()
    expect(screen.getAllByRole('button', { name: 'Save the report' })).toHaveLength(1)
  })
  it('says there is nothing to open for a group the person does not coach, without an error banner', async () => {
    api.fetchAdminPersonaAssignableCohorts.mockResolvedValue([{ id: 2, name: bog.name, status: 'enrolling', savings_challenge_enabled: true }])
    reports.exports.mockRejectedValue(new ApiRequestError('unavailable', { status: 403, code: null, errors: [], conflicts: [], payload: {} }))
    render(<ReportsSection currentUser={reviewerUser()} />)
    expect(await screen.findByText(/kept by the people who coach it/)).toBeTruthy()
    expect(screen.queryByRole('alert')).toBeNull()
  })
  it('re-checks the report belongs to this group before a download, and refuses one that does not', async () => {
    const created = vi.spyOn(URL, 'createObjectURL').mockReturnValue('blob:report'); vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {}); vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
    reports.exports.mockResolvedValue(index({ records: [{ id: 4, checkpoint_day: 30, resolved_cutoff_on: '2026-11-09' }] }))
    reports.report.mockResolvedValue({ cohort_id: 2, export_id: 4, report })
    render(<ReportsSection currentUser={adminUser()} />)
    fireEvent.click(await screen.findByRole('button', { name: 'View report' }))
    reports.report.mockClear()
    fireEvent.click(await screen.findByRole('button', { name: 'Download this report' }))
    await waitFor(() => expect(created).toHaveBeenCalledTimes(1))
    expect(reports.report).toHaveBeenCalledWith(2, 4, expect.any(AbortSignal))
    reports.report.mockResolvedValue({ cohort_id: 9, export_id: 4, report })
    fireEvent.click(screen.getByRole('button', { name: 'Download this report' }))
    expect((await screen.findByRole('alert')).textContent).toContain('no longer matches this group')
    expect(created).toHaveBeenCalledTimes(1)
  })
  it('follows the pages of saved reports, and shows a button when there are still more', async () => {
    reports.exports.mockImplementation((_id: number, cursor: number | null) => Promise.resolve(cursor === null
      ? index({ records: [{ id: 1, checkpoint_day: 90, resolved_cutoff_on: '2027-01-01' }], next_cursor: 1 })
      : index({ records: [{ id: 4, checkpoint_day: 30, resolved_cutoff_on: '2026-11-09' }], next_cursor: cursor < 6 ? cursor + 1 : null })))
    render(<ReportsSection currentUser={adminUser()} />)
    expect(await screen.findByRole('button', { name: 'Show earlier saved reports' })).toBeTruthy()
    expect(reports.exports).toHaveBeenCalledTimes(5)
    expect(screen.getAllByText(/Report saved/)).toHaveLength(2)
    fireEvent.click(screen.getByRole('button', { name: 'Show earlier saved reports' }))
    await waitFor(() => expect(reports.exports).toHaveBeenCalledTimes(6))
  })
})
