// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { PilotFeedbackDialog } from './PilotFeedbackDialog'
import * as api from '../api'
import { captureAnalyticsEvent } from '../lib/analytics'
vi.mock('../contexts/brandContextValue', () => ({ useBrand: () => ({ assistantName: 'Mia', brand: { product_name: 'VERA' } }) }))
vi.mock('../api', async original => ({ ...await original<typeof import('../api')>(), fetchMyPilotFeedback: vi.fn(), withdrawPilotFeedbackSupport: vi.fn() }))
vi.mock('../lib/analytics', () => ({ captureAnalyticsEvent: vi.fn(), trackPilotWorkflowFailure: vi.fn() }))
const receipt: api.PilotFeedbackReceipt = { id: 55, workflow: 'home', screenshot_attached: false, status: 'submitted', created_at: '', support_access_available: true, support_sharing_granted: true }
const consent = 'I agree to share this report and optional screenshot with app support administrators.'
beforeEach(() => { vi.clearAllMocks(); vi.mocked(api.fetchMyPilotFeedback).mockResolvedValue({ feedback_reports: [], next_cursor: null }) })
afterEach(cleanup)
function details() {
  fireEvent.change(screen.getByLabelText('What did you attempt?'), { target: { value: 'Open technical help' } })
  fireEvent.change(screen.getByLabelText('What did you expect?'), { target: { value: 'A readable button' } })
  fireEvent.change(screen.getByLabelText('What happened instead?'), { target: { value: 'A small button' } })
}
describe('report-only support sharing', () => {
  it('requires unchecked explicit approval and sends no financial scope or narrative to analytics', async () => {
    const submit = vi.fn().mockResolvedValue(receipt)
    render(<PilotFeedbackDialog initialWorkflow="home" onClose={vi.fn()} onSubmit={submit} />)
    details()
    expect((screen.getByRole('button', { name: 'Submit report' }) as HTMLButtonElement).disabled).toBe(true)
    fireEvent.submit(screen.getByRole('button', { name: 'Submit report' }).closest('form')!)
    expect(submit).not.toHaveBeenCalled()
    fireEvent.click(screen.getByLabelText(consent)); fireEvent.click(screen.getByRole('button', { name: 'Submit report' }))
    await screen.findByText('Report received.')
    expect(submit).toHaveBeenCalledWith({ workflow: 'home', attempted: 'Open technical help', expected: 'A readable button', actual: 'A small button', screenshot: null, share_with_support: true })
    expect(captureAnalyticsEvent).toHaveBeenCalledWith('pilot_feedback_report_submitted', { workflow: 'home', screenshot_attached: false })
    expect(screen.getByRole('button', { name: 'Withdraw support access to report #55' })).toBeTruthy()
  })
  it('withdraws confirmed report access and preserves a retry action after uncertainty', async () => {
    const submit = vi.fn().mockResolvedValue(receipt)
    vi.mocked(api.withdrawPilotFeedbackSupport).mockRejectedValueOnce(new Error('Withdrawal unconfirmed')).mockResolvedValueOnce({ ...receipt, support_access_available: false, support_sharing_granted: false })
    render(<PilotFeedbackDialog initialWorkflow="home" onClose={vi.fn()} onSubmit={submit} />)
    details(); fireEvent.click(screen.getByLabelText(consent)); fireEvent.click(screen.getByRole('button', { name: 'Submit report' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Withdraw support access to report #55' }))
    await screen.findByText('Withdrawal unconfirmed')
    fireEvent.click(screen.getByRole('button', { name: 'Withdraw support access to report #55' }))
    await screen.findByText('App support access is withdrawn or was not granted.')
    expect(api.withdrawPilotFeedbackSupport).toHaveBeenCalledTimes(2)
    expect(screen.queryByRole('button', { name: 'Withdraw support access to report #55' })).toBeNull()
  })
  it('loads only metadata on demand and pages earlier reports', async () => {
    vi.mocked(api.fetchMyPilotFeedback).mockResolvedValueOnce({ feedback_reports: [receipt], next_cursor: 55 }).mockResolvedValueOnce({ feedback_reports: [{ ...receipt, id: 54, support_access_available: false }], next_cursor: null })
    render(<PilotFeedbackDialog initialWorkflow="home" onClose={vi.fn()} onSubmit={vi.fn()} />)
    expect(api.fetchMyPilotFeedback).not.toHaveBeenCalled()
    const history = screen.getByText('My submitted reports').closest('details')!
    history.open = true; fireEvent(history, new Event('toggle'))
    await screen.findByText('Report #55')
    fireEvent.click(screen.getByRole('button', { name: 'Load earlier reports' }))
    await screen.findByText('Report #54')
    expect(api.fetchMyPilotFeedback).toHaveBeenLastCalledWith(55, expect.any(AbortSignal))
  })
  it.each([true, false])('resumes the cancelled earlier page without applying its late result; withdrawal confirmed: %s', async confirmed => {
    type History = Awaited<ReturnType<typeof api.fetchMyPilotFeedback>>
    let resolvePage!: (page: History) => void
    let resolveWithdrawal!: (report: api.PilotFeedbackReceipt) => void
    let rejectWithdrawal!: (error: Error) => void
    vi.mocked(api.fetchMyPilotFeedback).mockResolvedValueOnce({ feedback_reports: [receipt], next_cursor: 55 })
      .mockImplementationOnce(() => new Promise(resolve => { resolvePage = resolve }))
      .mockResolvedValueOnce({ feedback_reports: [{ ...receipt, id: 54 }], next_cursor: null })
    vi.mocked(api.withdrawPilotFeedbackSupport).mockImplementationOnce(() => new Promise((resolve, reject) => { resolveWithdrawal = resolve; rejectWithdrawal = reject }))
    render(<PilotFeedbackDialog initialWorkflow="home" onClose={vi.fn()} onSubmit={vi.fn()} />)
    const history = screen.getByText('My submitted reports').closest('details')!
    history.open = true; fireEvent(history, new Event('toggle')); await screen.findByText('Report #55')
    fireEvent.click(screen.getByRole('button', { name: 'Load earlier reports' }))
    const oldSignal = vi.mocked(api.fetchMyPilotFeedback).mock.calls[1][1]!
    fireEvent.click(screen.getByRole('button', { name: 'Withdraw support access to report #55' }))
    expect(oldSignal.aborted).toBe(true)
    expect(screen.getByRole('button', { name: 'Load earlier reports' })).toHaveProperty('disabled', true)
    expect(api.fetchMyPilotFeedback).toHaveBeenCalledTimes(2)
    await act(async () => { if (confirmed) resolveWithdrawal({ ...receipt, support_access_available: false, support_sharing_granted: false }); else rejectWithdrawal(new Error('Withdrawal unconfirmed')) })
    await screen.findByText('Report #54')
    expect(api.fetchMyPilotFeedback).toHaveBeenCalledTimes(3)
    expect(api.fetchMyPilotFeedback).toHaveBeenLastCalledWith(55, expect.any(AbortSignal))
    expect(vi.mocked(api.fetchMyPilotFeedback).mock.calls[2][1]!.aborted).toBe(false)
    await act(async () => { resolvePage({ feedback_reports: [{ ...receipt, id: 53 }], next_cursor: 53 }) })
    expect(screen.queryByText('Report #53')).toBeNull()
    expect(screen.getByText('Report #54')).toBeTruthy()
    if (confirmed) expect(screen.queryByRole('button', { name: 'Withdraw support access to report #55' })).toBeNull()
    else { expect(screen.getByText('Withdrawal unconfirmed')).toBeTruthy(); expect(screen.getByRole('button', { name: 'Withdraw support access to report #55' })).toHaveProperty('disabled', false) }
    expect(screen.queryByRole('button', { name: 'Load earlier reports' })).toBeNull()
  })
  it('cannot restore a confirmed withdrawal from stale replacement history metadata', async () => {
    type History = Awaited<ReturnType<typeof api.fetchMyPilotFeedback>>
    let resolveHistory!: (page: History) => void
    vi.mocked(api.fetchMyPilotFeedback).mockImplementationOnce(() => new Promise(resolve => { resolveHistory = resolve }))
      .mockResolvedValueOnce({ feedback_reports: [receipt], next_cursor: null })
    vi.mocked(api.withdrawPilotFeedbackSupport).mockResolvedValueOnce({ ...receipt, support_access_available: false, support_sharing_granted: false })
    render(<PilotFeedbackDialog initialWorkflow="home" onClose={vi.fn()} onSubmit={vi.fn().mockResolvedValue(receipt)} />)
    details(); fireEvent.click(screen.getByLabelText(consent)); fireEvent.click(screen.getByRole('button', { name: 'Submit report' }))
    await screen.findByText('Report received.')
    const history = screen.getByText('My submitted reports').closest('details')!
    history.open = true; fireEvent(history, new Event('toggle'))
    await waitFor(() => expect(api.fetchMyPilotFeedback).toHaveBeenCalledTimes(1))
    const oldSignal = vi.mocked(api.fetchMyPilotFeedback).mock.calls[0][1]!
    fireEvent.click(screen.getByRole('button', { name: 'Withdraw support access to report #55' }))
    await screen.findByText('Report #55')
    expect(oldSignal.aborted).toBe(true)
    await act(async () => { resolveHistory({ feedback_reports: [receipt], next_cursor: 55 }) })
    expect(api.fetchMyPilotFeedback).toHaveBeenCalledTimes(2)
    expect(screen.getAllByText('App support access is withdrawn or was not granted.')).toHaveLength(2)
    expect(screen.queryByText('App support can read this report and its optional screenshot.')).toBeNull()
    expect(screen.queryByRole('button', { name: 'Withdraw support access to report #55' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Load earlier reports' })).toBeNull()
  })
  it('ignores late submission after unmount and does not announce unsupported server access', async () => {
    let resolve!: (value: api.PilotFeedbackReceipt) => void
    const submit = vi.fn(() => new Promise<api.PilotFeedbackReceipt>(done => { resolve = done }))
    const view = render(<PilotFeedbackDialog initialWorkflow="home" onClose={vi.fn()} onSubmit={submit} />)
    details(); fireEvent.click(screen.getByLabelText(consent)); fireEvent.click(screen.getByRole('button', { name: 'Submit report' }))
    view.unmount(); await act(async () => resolve(receipt))
    expect(captureAnalyticsEvent).not.toHaveBeenCalled()
    render(<PilotFeedbackDialog initialWorkflow="home" onClose={vi.fn()} onSubmit={vi.fn().mockResolvedValue({ ...receipt, support_access_available: undefined })} />)
    details(); fireEvent.click(screen.getByLabelText(consent)); fireEvent.click(screen.getByRole('button', { name: 'Submit report' }))
    await screen.findByText('Report received.')
    expect(screen.queryByText('App support can read this report and its optional screenshot.')).toBeNull()
  })
  it('preserves typed details when server submission fails', async () => {
    render(<PilotFeedbackDialog initialWorkflow="home" onClose={vi.fn()} onSubmit={vi.fn().mockRejectedValue(new Error('Private storage unavailable'))} />)
    details(); fireEvent.click(screen.getByLabelText(consent)); fireEvent.click(screen.getByRole('button', { name: 'Submit report' }))
    await screen.findByText('Private storage unavailable')
    expect((screen.getByLabelText('What did you attempt?') as HTMLTextAreaElement).value).toBe('Open technical help')
    expect(screen.queryByText('Report received.')).toBeNull()
  })
})
