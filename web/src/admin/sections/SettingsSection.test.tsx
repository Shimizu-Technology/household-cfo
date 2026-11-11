// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { adminUser, group, savings, staff } from '../../test/adminFixtures'

const api = vi.hoisted(() => ({ fetchAdminCohorts: vi.fn(), fetchAdminUsers: vi.fn(), fetchAdminPlaidHealth: vi.fn() }))
vi.mock('../../api', async original => ({ ...await original<typeof import('../../api')>(), ...api }))
const auth = vi.hoisted(() => ({ workspaceId: 5 as number | null }))
vi.mock('../../contexts/authContextValue', () => ({ useAuthContext: () => ({ activeCoachWorkspaceId: auth.workspaceId, selectCoachWorkspace: vi.fn() }) }))
vi.mock('../../components/CoachProgramSettings', () => ({ CoachProgramSettings: () => <p>Program look form</p> }))
vi.mock('../../components/WorkspaceCollaborators', () => ({ WorkspaceCollaborators: () => <p>Team list</p> }))
vi.mock('../../components/EnterpriseSettings', () => ({ EnterpriseSettings: () => <p>Organization dialog</p> }))
import { SettingsSection } from './SettingsSection'

const titles = () => [...document.querySelectorAll('.admin-accordion > summary strong')].map(item => item.textContent?.replace(/[+−]$/, ''))
beforeEach(() => {
  vi.resetAllMocks(); auth.workspaceId = 5
  api.fetchAdminCohorts.mockResolvedValue([group(2, 'Bank of Guam 90 day savings', { savings_challenge: savings('open', { recent_events: [{ id: 1, action: 'open', reason: 'Kickoff is today', occurred_at: new Date().toISOString(), actor_name: 'Mrs. Mel' }] }) })])
  api.fetchAdminUsers.mockResolvedValue([])
  api.fetchAdminPlaidHealth.mockResolvedValue({ summary: { connected: 1, healthy: 1, attention_required: 0 }, items: [] })
})
afterEach(cleanup)

describe('Settings', () => {
  it('gives a program owner the look and the team only', async () => {
    render(<SettingsSection currentUser={staff()} onDirtyChange={vi.fn()} />)
    expect(titles()).toEqual(['Name and look', 'Your team'])
  })
  it('gives an admin programs, the rules, bank connections and activity too, in plain words', async () => {
    render(<SettingsSection currentUser={adminUser()} onDirtyChange={vi.fn()} />)
    expect(titles()).toEqual(['Name and look', 'Your team', 'Who can do what', 'Bank connections', 'Organization access', 'Activity'])
    fireEvent.click(screen.getByText('Bank connections'))
    expect(await screen.findByText(/never balances or transactions/)).toBeTruthy()
    expect(screen.queryByText(/Plaid/)).toBeNull()
  })
  it('lists what was changed, newest first, and filters by who made the change', async () => {
    render(<SettingsSection currentUser={adminUser()} onDirtyChange={vi.fn()} />)
    fireEvent.click(screen.getByText('Activity'))
    expect(await screen.findByText('Opened the savings challenge')).toBeTruthy()
    expect(screen.getByText('“Kickoff is today”')).toBeTruthy()
    fireEvent.change(screen.getByLabelText('Who made the change'), { target: { value: 'zed' } })
    expect(screen.getByText('No changes to show.')).toBeTruthy()
  })
  it('asks an admin who has not chosen a program to choose one, and offers only what works without one', async () => {
    auth.workspaceId = null
    render(<SettingsSection currentUser={adminUser()} onDirtyChange={vi.fn()} />)
    expect(screen.getByText('Choose a program at the top to change its look or team.')).toBeTruthy()
    expect(titles()).toEqual(['Programs', 'Who can do what', 'Bank connections', 'Organization access', 'Activity'])
  })
})
