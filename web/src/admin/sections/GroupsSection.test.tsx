// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { adminUser, group, person, savings, staff } from '../../test/adminFixtures'

const api = vi.hoisted(() => ({ fetchAdminCohorts: vi.fn(), fetchAdminUsers: vi.fn(), createAdminCohort: vi.fn(), updateAdminCohort: vi.fn(), fetchAdminPersonaAssignableCohorts: vi.fn() }))
vi.mock('../../api', async original => ({ ...await original<typeof import('../../api')>(), ...api }))
const auth = vi.hoisted(() => ({ workspaceId: 5 as number | null }))
vi.mock('../../contexts/authContextValue', () => ({ useAuthContext: () => ({ activeCoachWorkspaceId: auth.workspaceId, selectCoachWorkspace: vi.fn() }) }))
vi.mock('../../lib/useMatchMedia', () => ({ useMatchMedia: () => true }))
vi.mock('../../components/CohortExperienceStudio', () => ({ CohortExperienceStudio: () => <p>Tools for this group</p> }))
const nav = vi.hoisted(() => ({ navigateTo: vi.fn() }))
vi.mock('../../lib/appRoutes', async original => ({ ...await original<typeof import('../../lib/appRoutes')>(), ...nav }))
import { GroupsSection } from './GroupsSection'

const bog = group(2, 'Bank of Guam 90 day savings', { savings_challenge: savings('open', { capacity: 30 }) })
const household = group(3, 'Mel’s Household Group', { status: 'active', starts_on: '2026-10-01' })
beforeEach(() => {
  vi.resetAllMocks(); auth.workspaceId = 5
  api.fetchAdminCohorts.mockResolvedValue([bog, household, group(4, 'Old group', { status: 'archived' })])
  api.fetchAdminUsers.mockResolvedValue([person(1, 'Ana Lopez'), person(2, 'Bo Ng')])
  api.fetchAdminPersonaAssignableCohorts.mockResolvedValue([{ id: 2, name: bog.name, assignable: true, persona_assignment: { persona: { id: 1, name: 'Lani' } } }])
  api.updateAdminCohort.mockResolvedValue(bog); api.createAdminCohort.mockResolvedValue(group(8, 'New one'))
})
afterEach(cleanup)

describe('Groups', () => {
  it('lists groups with status, dates and who has joined, and hides archived ones', async () => {
    render(<GroupsSection currentUser={staff()} onDirtyChange={vi.fn()} />)
    const table = await screen.findByRole('table')
    expect(within(table).getAllByRole('columnheader').map(item => item.textContent)).toEqual(['Group', 'Status', 'Dates', 'Joined', 'Challenge'])
    const row = within(table).getByText('Bank of Guam 90 day savings').closest('tr')!
    expect(row.textContent).toContain('Signing up')
    expect(row.textContent).toContain('2 of 30')
    expect(row.textContent).toContain('Open')
    expect(screen.queryByText('Old group')).toBeNull()
  })
  it('creates a group from one short form, then opens it', async () => {
    render(<GroupsSection currentUser={staff()} onDirtyChange={vi.fn()} />)
    await screen.findByRole('table')
    fireEvent.click(screen.getByRole('button', { name: 'New group' }))
    fireEvent.change(screen.getByLabelText('Group name'), { target: { value: ' Evening group ' } })
    fireEvent.change(screen.getByLabelText('Start date (optional)'), { target: { value: '2026-12-01' } })
    fireEvent.click(screen.getByRole('button', { name: 'Create group' }))
    await waitFor(() => expect(api.createAdminCohort).toHaveBeenCalledWith({ name: 'Evening group', status: 'enrolling', starts_on: '2026-12-01' }))
  })
  it('asks a platform admin to choose a program before creating a group', async () => {
    auth.workspaceId = null
    render(<GroupsSection currentUser={adminUser()} onDirtyChange={vi.fn()} />)
    await screen.findByRole('table')
    fireEvent.click(screen.getByRole('button', { name: 'New group' }))
    fireEvent.change(screen.getByLabelText('Group name'), { target: { value: 'Somewhere' } })
    fireEvent.click(screen.getByRole('button', { name: 'Create group' }))
    expect(await screen.findByText(/Choose a program at the top of the page first/)).toBeTruthy()
    expect(api.createAdminCohort).not.toHaveBeenCalled()
  })
  it('opens a group to its challenge, details, voice link and tools, saving details with the version it saw', async () => {
    const dirty = vi.fn()
    render(<GroupsSection currentUser={staff()} onDirtyChange={dirty} />)
    fireEvent.click(await screen.findByRole('button', { name: 'Bank of Guam 90 day savings' }))
    expect(await screen.findByRole('heading', { name: 'Bank of Guam 90 day savings' })).toBeTruthy()
    expect(screen.getByText('Challenge status')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Pause the challenge' })).toBeTruthy()
    expect(await screen.findByText('Lani')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Change the voice' }))
    expect(nav.navigateTo).toHaveBeenCalledWith('/admin/coaching')
    fireEvent.change(screen.getByLabelText('Group name'), { target: { value: 'BOG savings' } })
    await waitFor(() => expect(dirty).toHaveBeenLastCalledWith(true))
    fireEvent.click(screen.getByRole('button', { name: 'Save group' }))
    await waitFor(() => expect(api.updateAdminCohort).toHaveBeenCalledWith(2, expect.objectContaining({ name: 'BOG savings', expected_updated_at: '2026-10-02T00:00:00Z' })))
    fireEvent.click(screen.getByRole('button', { name: 'Tools people can use' }))
    expect(screen.getByText('Tools for this group')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: '‹ All groups' }))
    expect(await screen.findByRole('table')).toBeTruthy()
  })
  it('shows no challenge controls for a group that does not run one', async () => {
    render(<GroupsSection currentUser={staff()} onDirtyChange={vi.fn()} />)
    fireEvent.click(await screen.findByRole('button', { name: 'Mel’s Household Group' }))
    await screen.findByRole('heading', { name: 'Mel’s Household Group' })
    expect(screen.queryByText('Challenge status')).toBeNull()
  })
})
