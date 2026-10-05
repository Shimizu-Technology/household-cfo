// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AdminCohort, AdminUser, CurrentUser } from '../api'
import { AdminConsole } from './AdminConsole'
const mocks = vi.hoisted(() => ({ fetchAdminCohorts: vi.fn(), fetchAdminUsers: vi.fn(), fetchAdminPlaidHealth: vi.fn(), updateAdminUser: vi.fn() }))
vi.mock('../api', async (original) => ({ ...await original<typeof import('../api')>(), ...mocks }))
vi.mock('../contexts/authContextValue', () => ({ useAuthContext: () => ({ activeCoachWorkspaceId: 2, selectCoachWorkspace: vi.fn() }) }))
vi.mock('./PilotFeedbackInbox', () => ({ PilotFeedbackInbox: () => <section>Private support inbox</section> }))
vi.mock('./CoachProgramSettings', () => ({ CreateCoachProgram: () => <section>Create program controls</section> }))
const cohort = { id: 10, name: 'BOG 90 day challenge', status: 'enrolling', starts_on: null, ends_on: null, notes: '', updated_at: '2026-10-04T12:00:00Z' } as AdminCohort
const people = Array.from({ length: 30 }, (_, index) => ({ id: 40 + index, email: `participant${index}@example.test`, full_name: `Participant ${String(index).padStart(2, '0')}`, role: 'participant', invitation_status: 'accepted', cohorts: [{ id: 100 + index, role: 'participant', cohort: { id: 10, name: cohort.name, status: 'enrolling' } }], invite_email: { workspace_scoped: true, status: 'not_sent', last_attempted_at: null }, workspace: { setup_complete: false, setup_status: 'not_started', signed_in: true, has_pending_review_work: false, last_safe_activity_at: null } })) as AdminUser[]
beforeEach(() => { vi.clearAllMocks(); mocks.fetchAdminCohorts.mockResolvedValue([cohort]); mocks.fetchAdminUsers.mockResolvedValue(people); mocks.fetchAdminPlaidHealth.mockResolvedValue({ summary: { connected: 0, healthy: 0, attention_required: 0 }, items: [] }); vi.spyOn(window, 'confirm').mockReturnValue(false) })
afterEach(() => { cleanup(); vi.restoreAllMocks() })
const actor = { id: 1, is_admin: true, coach_workspaces: [{ id: 2, name: 'Mel coaching' }] } as CurrentUser
describe('staff operation hierarchy', () => {
  it('starts with thirty compact access rows and separates settings from the participant task', async () => {
    render(<AdminConsole currentUser={actor} />)
    await screen.findAllByText('Participant 00')
    expect(document.querySelectorAll('.admin-user-row')).toHaveLength(15)
    fireEvent.click(screen.getByRole('button', { name: 'Next participants' }))
    expect(document.querySelector('.admin-user-row')?.textContent).toContain('Participant 15')
    expect(screen.getByText('Page 2 of 2')).toBeTruthy()
    expect(document.querySelectorAll('.admin-user-row[open]')).toHaveLength(0)
    expect(Array.from(document.querySelectorAll('.admin-user-controls button')).every((button) => !(button.closest('details') as HTMLDetailsElement).open)).toBe(true)
    expect(screen.queryByRole('heading', { name: 'Bank feed ledger' })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Support inbox' }))
    expect(document.querySelector('[hidden]')?.hasAttribute('hidden')).toBe(true)
    expect(screen.queryByRole('heading', { name: /members/ })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Participants & access' }))
    expect(screen.getByRole('heading', { name: /members/ })).toBeTruthy()
    fireEvent.change(screen.getByLabelText('Search'), { target: { value: 'Participant 29' } })
    expect(document.querySelectorAll('.admin-user-row')).toHaveLength(1)
    expect(document.querySelector('.admin-user-row')?.textContent).toContain('participant29@example.test')
  })
  it('retains an unsaved per-person edit across operation areas and guards cohort changes', async () => {
    render(<AdminConsole currentUser={actor} />)
    await screen.findAllByText('Participant 00')
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
})
