// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { adminUser, group, savings } from '../../test/adminFixtures'

const api = vi.hoisted(() => ({ fetchAdminCohorts: vi.fn(), fetchAdminUsers: vi.fn() }))
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
})
