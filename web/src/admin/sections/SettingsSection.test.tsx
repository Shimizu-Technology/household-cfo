// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { adminUser, group, savings, staff } from '../../test/adminFixtures'

const api = vi.hoisted(() => ({ fetchAdminCohorts: vi.fn(), fetchAdminUsers: vi.fn(), fetchAdminPlaidHealth: vi.fn() }))
vi.mock('../../api', async original => ({ ...await original<typeof import('../../api')>(), ...api }))
const auth = vi.hoisted(() => ({ workspaceId: 5 as number | null }))
vi.mock('../../contexts/authContextValue', () => ({ useAuthContext: () => ({ activeCoachWorkspaceId: auth.workspaceId, selectCoachWorkspace: vi.fn() }) }))
type Dirty = { onDirtyChange: (dirty: boolean) => void }
vi.mock('../../components/CoachProgramSettings', () => ({ CoachProgramSettings: ({ onDirtyChange }: Dirty) => <><p>Program look form</p><button onClick={() => onDirtyChange(true)}>Edit the look</button><button onClick={() => onDirtyChange(false)}>Save the look</button></> }))
vi.mock('../../components/WorkspaceCollaborators', () => ({ WorkspaceCollaborators: ({ onDirtyChange }: Dirty) => <><p>Team list</p><button onClick={() => onDirtyChange(true)}>Edit the team</button><button onClick={() => onDirtyChange(false)}>Save the team</button></> }))
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
  it('labels the activity list for what it really is, and filters by the group itself', async () => {
    const event = (id: number, reason: string) => ({ id, action: 'pause', reason, occurred_at: new Date().toISOString(), actor_name: 'Mrs. Mel' })
    api.fetchAdminCohorts.mockResolvedValue([
      group(2, 'Same name', { savings_challenge: savings('paused', { recent_events: [event(1, 'First group reason')] }) }),
      group(3, 'Same name', { savings_challenge: savings('paused', { recent_events: [event(2, 'Second group reason')] }) }),
    ])
    render(<SettingsSection currentUser={adminUser()} onDirtyChange={vi.fn()} />)
    fireEvent.click(screen.getByText('Activity'))
    expect(await screen.findByText(/When a savings challenge was opened or paused, and why. Other changes aren’t listed here yet./)).toBeTruthy()
    fireEvent.change(screen.getByLabelText('Group'), { target: { value: '3' } })
    expect(screen.getByText('“Second group reason”')).toBeTruthy()
    expect(screen.queryByText('“First group reason”')).toBeNull()
  })
  it('keeps warning about unsaved changes until both forms are saved', () => {
    const dirty = vi.fn()
    const { unmount } = render(<SettingsSection currentUser={staff()} onDirtyChange={dirty} />)
    fireEvent.click(screen.getByText('Edit the look')); fireEvent.click(screen.getByText('Edit the team'))
    expect(dirty).toHaveBeenLastCalledWith(true)
    fireEvent.click(screen.getByText('Save the look'))
    expect(dirty).toHaveBeenLastCalledWith(true)
    fireEvent.click(screen.getByText('Save the team'))
    expect(dirty).toHaveBeenLastCalledWith(false)
    fireEvent.click(screen.getByText('Edit the team')); fireEvent.click(screen.getByText('Edit the look'))
    fireEvent.click(screen.getByText('Save the team'))
    expect(dirty).toHaveBeenLastCalledWith(true)
    unmount()
    expect(dirty).toHaveBeenLastCalledWith(false)
  })
  it('says the activity is loading, and offers a retry when it could not be loaded, instead of "No changes"', async () => {
    api.fetchAdminCohorts.mockRejectedValueOnce(new Error('The groups could not be loaded.'))
    render(<SettingsSection currentUser={adminUser()} onDirtyChange={vi.fn()} />)
    expect(screen.getByText('Opening the activity…')).toBeTruthy()
    expect(await screen.findByText(/The groups could not be loaded\./)).toBeTruthy()
    expect(screen.queryByText('No changes to show.')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(await screen.findByText('Opened the savings challenge')).toBeTruthy()
  })
  it('does not call an unreadable bank connection list "no connections"', async () => {
    api.fetchAdminPlaidHealth.mockRejectedValue(new Error('down'))
    render(<SettingsSection currentUser={adminUser()} onDirtyChange={vi.fn()} />)
    fireEvent.click(screen.getByText('Bank connections'))
    expect(await screen.findByText(/Bank connection status isn’t available right now/)).toBeTruthy()
    expect(screen.queryByText('No bank connections yet.')).toBeNull()
    expect(screen.queryByText(/need attention/)).toBeNull()
  })
})
