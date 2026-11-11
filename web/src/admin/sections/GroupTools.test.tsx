// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const api = vi.hoisted(() => ({ fetchAdminPersonaAssignableCohorts: vi.fn() }))
vi.mock('../../api', async original => ({ ...await original<typeof import('../../api')>(), ...api }))
vi.mock('../../contexts/authContextValue', () => ({ useAuthContext: () => ({ activeCoachWorkspaceId: 5, selectCoachWorkspace: vi.fn() }) }))
const studio = vi.hoisted(() => ({ props: [] as Array<{ fixedGroup: boolean; cohorts: Array<{ id: number }> }> }))
vi.mock('../../components/CohortExperienceStudio', () => ({ CohortExperienceStudio: (props: { fixedGroup: boolean; cohorts: Array<{ id: number; name: string }> }) => { studio.props.push(props); return <p>Studio for {props.cohorts.map(item => item.name).join(', ')}</p> } }))
import { GroupTools } from './GroupTools'

const cohort = (id: number, name: string) => ({ id, name, status: 'active', assignable: true, blocked_reason: null, persona_assignment: null })
beforeEach(() => { vi.resetAllMocks(); studio.props = [] })
afterEach(cleanup)

describe('Group tools', () => {
  it('says it is loading, then shows the tools of the one group on its page', async () => {
    api.fetchAdminPersonaAssignableCohorts.mockResolvedValue([cohort(2, 'BOG'), cohort(3, 'Household')])
    render(<GroupTools groupId={3} onDirtyChange={vi.fn()} />)
    expect(screen.getByRole('status').textContent).toContain('Opening the tools')
    expect(await screen.findByText('Studio for Household')).toBeTruthy()
    expect(studio.props.at(-1)?.fixedGroup).toBe(true)
  })

  it('offers a choice of groups under Coaching', async () => {
    api.fetchAdminPersonaAssignableCohorts.mockResolvedValue([cohort(2, 'BOG'), cohort(3, 'Household')])
    render(<GroupTools onDirtyChange={vi.fn()} />)
    expect(await screen.findByText('Studio for BOG, Household')).toBeTruthy()
    expect(studio.props.at(-1)?.fixedGroup).toBe(false)
  })

  it('never spins forever: a failed read says so and offers a retry', async () => {
    api.fetchAdminPersonaAssignableCohorts.mockRejectedValueOnce(new Error('offline')).mockResolvedValue([cohort(2, 'BOG')])
    render(<GroupTools groupId={2} onDirtyChange={vi.fn()} />)
    expect((await screen.findByRole('alert')).textContent).toContain('couldn’t be opened')
    expect(screen.queryByRole('status')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(await screen.findByText('Studio for BOG')).toBeTruthy()
  })

  it('says so when there are no groups, rather than loading', async () => {
    api.fetchAdminPersonaAssignableCohorts.mockResolvedValue([])
    render(<GroupTools onDirtyChange={vi.fn()} />)
    expect(await screen.findByText(/no groups for you to set tools for yet/)).toBeTruthy()
    expect(screen.queryByRole('status')).toBeNull()
  })

  it('says so when the group is not one the person may see', async () => {
    api.fetchAdminPersonaAssignableCohorts.mockResolvedValue([cohort(2, 'BOG')])
    render(<GroupTools groupId={9} onDirtyChange={vi.fn()} />)
    expect(await screen.findByText('The tools for this group aren’t available to you.')).toBeTruthy()
  })

  it('ignores a slow answer that arrives after the person has left', async () => {
    let answer!: (value: unknown) => void
    api.fetchAdminPersonaAssignableCohorts.mockImplementation(() => new Promise(resolve => { answer = resolve }))
    const complaints = vi.spyOn(console, 'error').mockImplementation(() => {})
    const view = render(<GroupTools groupId={2} onDirtyChange={vi.fn()} />)
    await waitFor(() => expect(api.fetchAdminPersonaAssignableCohorts).toHaveBeenCalled())
    view.unmount()
    answer([cohort(2, 'Late')])
    await new Promise(resolve => setTimeout(resolve, 10))
    expect(studio.props).toHaveLength(0)
    expect(complaints).not.toHaveBeenCalled()
    complaints.mockRestore()
  })
})
