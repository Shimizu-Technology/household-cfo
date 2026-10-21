// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AdminPilotFeedbackDetail } from '../api'
import { PilotFeedbackInbox } from './PilotFeedbackInbox'

const mocks = vi.hoisted(() => ({ fetchAdminPilotFeedback: vi.fn(), fetchAdminPilotFeedbackReport: vi.fn(), fetchAdminPilotFeedbackScreenshotUrl: vi.fn(), updateAdminPilotFeedbackStatus: vi.fn() }))
vi.mock('../api', () => mocks)
const report = { id: 7, workflow: 'admin', status: 'submitted', reporter: { full_name: 'Ana Cruz', email: 'ana@example.test' }, created_at: '2026-10-22T10:00:00Z', attempted: 'Find my invitation', expected: 'A clear next step', actual: 'I already joined', screenshot: null } as AdminPilotFeedbackDetail
beforeEach(() => {
  vi.resetAllMocks()
  mocks.fetchAdminPilotFeedback.mockResolvedValue({ feedback_reports: [report], counts: { submitted: 1, reviewed: 0, resolved: 0 } })
  mocks.fetchAdminPilotFeedbackReport.mockResolvedValue(report)
})
afterEach(cleanup)

describe('PilotFeedbackInbox', () => {
  it('shows the current status as text and only offers meaningful next statuses', async () => {
    render(<PilotFeedbackInbox />)
    await screen.findByText('Find my invitation')
    expect(screen.queryByRole('button', { name: 'Reopen' })).toBeNull()
    expect(screen.getByRole('button', { name: 'Mark reviewed' })).toHaveProperty('disabled', false)
    expect(screen.getByRole('button', { name: 'Mark resolved' })).toHaveProperty('disabled', false)
  })
  it('locks report navigation while saving, reports pending state, and refreshes saved counts', async () => {
    let complete!: (report: AdminPilotFeedbackDetail) => void
    mocks.updateAdminPilotFeedbackStatus.mockImplementation(() => new Promise((resolve) => { complete = resolve }))
    const onPendingChange = vi.fn()
    render(<PilotFeedbackInbox onPendingChange={onPendingChange} />)
    await screen.findByText('Find my invitation')
    fireEvent.click(screen.getByRole('button', { name: 'Mark reviewed' }))
    expect(onPendingChange).toHaveBeenLastCalledWith(true)
    expect(screen.getByText('Saving feedback status…')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'All 1' })).toHaveProperty('disabled', true)
    expect(screen.getByRole('button', { name: /Admin New Ana Cruz/ })).toHaveProperty('disabled', true)
    expect(screen.getByRole('button', { name: 'Refresh feedback' })).toHaveProperty('disabled', true)
    mocks.fetchAdminPilotFeedback.mockResolvedValue({ feedback_reports: [], counts: { submitted: 0, reviewed: 1, resolved: 0 } })
    await act(async () => complete({ ...report, status: 'reviewed' }))
    await screen.findByText('Feedback marked reviewed.')
    await waitFor(() => expect(onPendingChange).toHaveBeenLastCalledWith(false))
    expect(screen.getByRole('button', { name: 'Reviewed 1' })).toHaveProperty('disabled', false)
    expect(mocks.updateAdminPilotFeedbackStatus).toHaveBeenCalledWith(7, 'reviewed')
  })
  it('keeps a failed save recoverable with the same selected report', async () => {
    mocks.updateAdminPilotFeedbackStatus.mockRejectedValue(new Error('Please try again'))
    render(<PilotFeedbackInbox />)
    await screen.findByText('Find my invitation')
    fireEvent.click(screen.getByRole('button', { name: 'Mark resolved' }))
    await screen.findByText('Please try again')
    await waitFor(() => expect(screen.getByRole('button', { name: 'Mark resolved' })).toHaveProperty('disabled', false))
    expect(screen.getByText('Find my invitation')).toBeTruthy()
  })
})
