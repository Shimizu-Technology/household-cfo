// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { adminUser, staff } from '../../test/adminFixtures'

const api = vi.hoisted(() => ({ fetchAdminPilotFeedback: vi.fn(), fetchAdminPilotFeedbackReport: vi.fn(), fetchAdminPilotFeedbackScreenshotUrl: vi.fn(), updateAdminPilotFeedbackStatus: vi.fn() }))
vi.mock('../../api', async original => ({ ...await original<typeof import('../../api')>(), ...api }))
const setup = vi.hoisted(() => ({ fetchSetupSupportRequests: vi.fn(), updateSetupSupportRequest: vi.fn() }))
vi.mock('../../setupHelpApi', () => setup)
const auth = vi.hoisted(() => ({ workspaceId: 5 as number | null }))
vi.mock('../../contexts/authContextValue', () => ({ useAuthContext: () => ({ activeCoachWorkspaceId: auth.workspaceId, selectCoachWorkspace: vi.fn() }) }))
vi.mock('../../components/SetupSupportInbox', () => ({ SetupSupportInbox: () => <p>Setup request details</p> }))
import { SupportSection } from './SupportSection'

const request = (id: number, name: string, status: string, created_at: string) => ({ id, status, participant_name: name, user_id: id, cohort_id: 2, reason: 'upload_problem', reason_label: 'I need help with an upload', created_at })
const problem = (id: number, name: string, status: string, created_at: string) => ({ id, status, workflow: 'budget', reporter: { id, email: `${name}@x.test`, full_name: name }, created_at })
beforeEach(() => {
  vi.resetAllMocks(); auth.workspaceId = 5
  setup.fetchSetupSupportRequests.mockResolvedValue({ records: [request(1, 'Bog One', 'requested', '2026-11-10T10:00:00Z'), request(2, 'Old Request', 'applied', '2026-11-01T10:00:00Z')], next_cursor: null })
  api.fetchAdminPilotFeedback.mockResolvedValue({ feedback_reports: [problem(7, 'Pat Participant', 'submitted', '2026-11-11T09:00:00Z')], counts: {} })
  api.fetchAdminPilotFeedbackReport.mockResolvedValue({ ...problem(7, 'Pat Participant', 'submitted', '2026-11-11T09:00:00Z'), attempted: 'Edit rent', expected: 'It saves', actual: 'An error', screenshot: null })
  api.updateAdminPilotFeedbackStatus.mockResolvedValue({ ...problem(7, 'Pat Participant', 'resolved', '2026-11-11T09:00:00Z'), attempted: 'Edit rent', expected: 'It saves', actual: 'An error', screenshot: null })
})
afterEach(cleanup)

describe('Support', () => {
  it('puts setup requests and problem reports in one list, newest first, with plain status', async () => {
    render(<SupportSection currentUser={adminUser()} />)
    const list = await screen.findByRole('list')
    const items = within(list).getAllByRole('listitem')
    expect(items.map(item => item.textContent)).toEqual([expect.stringContaining('Pat Participant'), expect.stringContaining('Bog One')])
    expect(items[0].textContent).toContain('Reported a problem: Budget')
    expect(items[0].textContent).toContain('New')
    expect(items[1].textContent).toContain('Setup help: needs help with an upload')
    expect(items[1].textContent).toContain('Waiting for you')
  })
  it('keeps finished requests under Done and everything under Everything', async () => {
    render(<SupportSection currentUser={adminUser()} />)
    await screen.findByText('Bog One')
    expect(screen.queryByText('Old Request')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: /Done/ }))
    expect(screen.getByText('Old Request')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: /Everything/ }))
    expect(screen.getAllByRole('listitem')).toHaveLength(3)
  })
  it('opens a setup request to its actions, and a problem to what happened with a way to mark it done', async () => {
    render(<SupportSection currentUser={adminUser()} />)
    fireEvent.click(await screen.findByRole('button', { name: /Bog One/ }))
    expect(screen.getByText('Setup request details')).toBeTruthy()
    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Close' }))
    fireEvent.click(await screen.findByRole('button', { name: /Pat Participant/ }))
    expect(await screen.findByText('An error')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Mark as done' }))
    await waitFor(() => expect(api.updateAdminPilotFeedbackStatus).toHaveBeenCalledWith(7, 'resolved'))
  })
  it('shows problem reports only to platform admins, and asks a platform admin to choose a program for setup requests', async () => {
    const { unmount } = render(<SupportSection currentUser={staff()} />)
    await screen.findByText('Bog One')
    expect(api.fetchAdminPilotFeedback).not.toHaveBeenCalled()
    expect(screen.queryByText('Pat Participant')).toBeNull()
    unmount(); auth.workspaceId = null
    render(<SupportSection currentUser={adminUser()} />)
    expect(await screen.findByText('Choose a program at the top to see its setup requests.')).toBeTruthy()
  })
  it('follows every page of setup requests, so a newer request past the first page still counts', async () => {
    setup.fetchSetupSupportRequests
      .mockResolvedValueOnce({ records: [request(1, 'Bog One', 'requested', '2026-11-10T10:00:00Z')], next_cursor: 1 })
      .mockResolvedValueOnce({ records: [request(2, 'Late Request', 'requested', '2026-11-10T11:00:00Z')], next_cursor: null })
    render(<SupportSection currentUser={adminUser()} />)
    expect(await screen.findByText('Late Request')).toBeTruthy()
    expect(screen.getByText('Bog One')).toBeTruthy()
    expect(setup.fetchSetupSupportRequests).toHaveBeenNthCalledWith(2, null, 1)
    expect(screen.getByRole('button', { name: /Needs a look/ }).textContent).toContain('3')
  })
  it('lets only the newest refresh write to the screen when two finish out of order', async () => {
    let finishFirst: (value: unknown) => void = () => {}
    setup.fetchSetupSupportRequests
      .mockResolvedValueOnce({ records: [request(1, 'Bog One', 'requested', '2026-11-10T10:00:00Z')], next_cursor: null })
      .mockReturnValueOnce(new Promise(resolve => { finishFirst = resolve }))
      .mockResolvedValueOnce({ records: [request(1, 'Bog One', 'applied', '2026-11-10T10:00:00Z')], next_cursor: null })
    render(<SupportSection currentUser={adminUser()} />)
    fireEvent.click(await screen.findByText('Bog One'))
    const dialog = await screen.findByRole('dialog')
    fireEvent.click(within(dialog).getByRole('button', { name: 'Close' }))
    await waitFor(() => expect(setup.fetchSetupSupportRequests).toHaveBeenCalledTimes(2))
    fireEvent.click(await screen.findByText('Bog One'))
    fireEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: 'Close' }))
    await waitFor(() => expect(setup.fetchSetupSupportRequests).toHaveBeenCalledTimes(3))
    await waitFor(() => expect(screen.getByRole('button', { name: /Done/ }).textContent).toContain('1'))
    finishFirst({ records: [request(1, 'Bog One', 'requested', '2026-11-10T10:00:00Z')], next_cursor: null })
    await new Promise(resolve => setTimeout(resolve, 20))
    expect(screen.getByRole('button', { name: /Done/ }).textContent).toContain('1')
    expect(screen.getByRole('button', { name: /Needs a look/ }).textContent).toContain('1')
  })
})
