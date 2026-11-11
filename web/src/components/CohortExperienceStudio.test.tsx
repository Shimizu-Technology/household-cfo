// @vitest-environment jsdom

import { cleanup, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AdminPersonaAssignableCohort, CohortExperienceConfiguration } from '../api'
import { CohortExperienceStudio } from './CohortExperienceStudio'

const apiMocks = vi.hoisted(() => ({
  fetchCohortExperienceConfiguration: vi.fn(),
  updateCohortExperienceConfiguration: vi.fn(),
  rollbackCohortExperienceConfiguration: vi.fn(),
}))
vi.mock('../api', async (importOriginal) => ({ ...await importOriginal<typeof import('../api')>(), ...apiMocks }))

const cohorts = [{ id: 5, name: 'BOG pilot', status: 'enrolling' }] as AdminPersonaAssignableCohort[]
const configuration = (draft: CohortExperienceConfiguration['draft']): CohortExperienceConfiguration => ({
  cohort: { id: 5, name: 'BOG pilot', status: 'enrolling', participant_count: 0 },
  draft, draft_revision: 1, preview_required: true, preview: null, published_version: null, versions: [],
  permissions: { edit: true, review: true, publish: true, rollback: true },
})
const household = configuration({ schema_version: 1, optional_modules: { cfo_filter: false, optionality: false } })
const lifecycle = { pending: false, begin: vi.fn(() => ({ id: 1, workspaceId: 1 })), isCurrent: vi.fn(() => true), finish: vi.fn() }

function renderStudio() {
  return render(<CohortExperienceStudio cohorts={cohorts} cohortsLoading={false} mutationLifecycle={lifecycle as never} onDirtyChange={vi.fn()} selectedCohortId={5} onSelectedCohortIdChange={vi.fn()} />)
}

beforeEach(() => {
  vi.resetAllMocks()
  lifecycle.begin.mockReturnValue({ id: 1, workspaceId: 1 })
  lifecycle.isCurrent.mockReturnValue(true)
  apiMocks.fetchCohortExperienceConfiguration.mockResolvedValue(household)
})
afterEach(cleanup)

describe('CohortExperienceStudio experience choice', () => {
  it('defaults to Household CFO and shows its tabs', async () => {
    renderStudio()
    const household = await screen.findByRole('radio', { name: /Household CFO/ })
    expect(household).toHaveProperty('checked', true)
    const summary = screen.getByLabelText('Navigation participants will see')
    expect(summary.textContent).toContain('Budget')
    expect(summary.textContent).not.toContain('Savings')
  })

  it('switching to the Savings Challenge shows the savings tabs and saves schema 3', async () => {
    const user = userEvent.setup()
    const saved = configuration({ schema_version: 3, experience_mode: 'savings_challenge', optional_modules: { cfo_filter: false, optionality: false } })
    apiMocks.updateCohortExperienceConfiguration.mockResolvedValue(saved)
    renderStudio()
    await user.click(await screen.findByRole('radio', { name: /90-day Savings Challenge/ }))
    const summary = screen.getByLabelText('Navigation participants will see')
    expect(within(summary).getByText('Savings')).toBeTruthy()
    expect(within(summary).getByText('Statements')).toBeTruthy()
    expect(within(summary).queryByText('Budget')).toBeNull()
    expect(screen.getByRole('switch', { name: 'Include CFO Filter' })).toHaveProperty('checked', false)
    await user.click(screen.getByRole('button', { name: 'Save draft' }))
    await waitFor(() => expect(apiMocks.updateCohortExperienceConfiguration).toHaveBeenCalledWith(5, 1, { schema_version: 3, experience_mode: 'savings_challenge', optional_modules: { cfo_filter: false, optionality: false } }))
  })

  it('switching back drops the mode and keeps ordinary optional tools', async () => {
    const user = userEvent.setup()
    apiMocks.fetchCohortExperienceConfiguration.mockResolvedValue(configuration({ schema_version: 3, experience_mode: 'savings_challenge', optional_modules: { cfo_filter: false, optionality: false } }))
    apiMocks.updateCohortExperienceConfiguration.mockResolvedValue(household)
    renderStudio()
    expect((await screen.findByRole('radio', { name: /90-day Savings Challenge/ })) as HTMLInputElement).toHaveProperty('checked', true)
    await user.click(screen.getByRole('radio', { name: /Household CFO/ }))
    expect(screen.getByRole('switch', { name: 'Include CFO Filter' })).toBeTruthy()
    await user.click(screen.getByRole('button', { name: 'Save draft' }))
    await waitFor(() => expect(apiMocks.updateCohortExperienceConfiguration).toHaveBeenCalledWith(5, 1, { schema_version: 1, optional_modules: { cfo_filter: false, optionality: false } }))
  })

  it('lets a coach hide every non-core module while keeping Statements independent', async () => {
    const user = userEvent.setup()
    renderStudio()
    await screen.findByRole('switch', { name: 'Include Review' })
    expect(screen.queryByRole('switch', { name: 'Include Home' })).toBeNull()
    expect(screen.queryByRole('switch', { name: 'Include Ask Mia' })).toBeNull()
    for (const name of ['Review', 'Budget', 'My Profile', 'Wealth']) {
      await user.click(screen.getByRole('switch', { name: `Include ${name}` }))
    }
    const summary = screen.getByLabelText('Navigation participants will see')
    expect(summary.textContent).toContain('Statements')
    expect(summary.textContent).not.toContain('My Money')
    expect(summary.textContent).not.toContain('Budget')
    await user.click(screen.getByRole('switch', { name: 'Include Statements' }))
    expect(summary.textContent).not.toContain('Statements')
    const expected = { schema_version: 4, experience_mode: 'household_cfo', module_order: [], optional_modules: {
      review: false, budget: false, profile: false, statements: false, wealth: false, cfo_filter: false, optionality: false,
    } }
    apiMocks.updateCohortExperienceConfiguration.mockResolvedValue(configuration(expected as CohortExperienceConfiguration['draft']))
    await user.click(screen.getByRole('button', { name: 'Save draft' }))
    await waitFor(() => expect(apiMocks.updateCohortExperienceConfiguration).toHaveBeenCalledWith(5, 1, expected))
  })

  it('orders primary navigation and retains module choices when changing experience', async () => {
    const user = userEvent.setup()
    renderStudio()
    await screen.findByRole('button', { name: 'Move Review up' })
    await user.click(screen.getByRole('switch', { name: 'Include Wealth' }))
    await user.click(screen.getByRole('button', { name: 'Move Review up' }))
    const order = within(screen.getByRole('list', { name: 'Participant tool order' })).getAllByRole('listitem')
    expect(order[0].textContent).toContain('Review')
    const summary = screen.getByLabelText('Navigation participants will see')
    expect(within(summary).getAllByText(/Review|Home|Ask Mia|Budget/, { selector: 'b' }).map(item => item.textContent)).toEqual(['Review', 'Home', 'Ask Mia', 'Budget'])
    await user.click(screen.getByRole('radio', { name: /90-day Savings Challenge/ }))
    expect(screen.getByRole('switch', { name: 'Include Wealth' })).toHaveProperty('checked', false)
    const expected = { schema_version: 4, experience_mode: 'savings_challenge', module_order: ['review', 'home', 'ask_mia', 'budget', 'profile', 'wealth', 'cfo_filter', 'optionality', 'statements'], optional_modules: {
      review: true, budget: true, profile: true, statements: true, wealth: false, cfo_filter: false, optionality: false,
    } }
    apiMocks.updateCohortExperienceConfiguration.mockResolvedValue(configuration(expected as CohortExperienceConfiguration['draft']))
    await user.click(screen.getByRole('button', { name: 'Save draft' }))
    await waitFor(() => expect(apiMocks.updateCohortExperienceConfiguration).toHaveBeenCalledWith(5, 1, expected))
  })

  it('restores default navigation order while preserving hidden modules', async () => {
    const user = userEvent.setup()
    const custom = configuration({ schema_version: 4, experience_mode: 'household_cfo', module_order: ['budget', 'review', 'ask_mia', 'home'], optional_modules: {
      review: true, budget: true, profile: false, statements: true, wealth: false, cfo_filter: false, optionality: false,
    } })
    apiMocks.fetchCohortExperienceConfiguration.mockResolvedValue(custom)
    if (custom.draft.schema_version !== 4) throw new Error("Expected a schema 4 fixture")
    const expected = { ...custom.draft, module_order: [] }
    apiMocks.updateCohortExperienceConfiguration.mockResolvedValue(configuration(expected))
    renderStudio()
    await user.click(await screen.findByRole('button', { name: 'Use the usual order' }))
    expect(screen.getByRole('switch', { name: 'Include Wealth' })).toHaveProperty('checked', false)
    const summary = screen.getByLabelText('Navigation participants will see')
    expect(within(summary).getAllByText(/Home|Ask Mia|Budget|Review/, { selector: 'b' }).map(item => item.textContent)).toEqual(['Home', 'Ask Mia', 'Budget', 'Review'])
    await user.click(screen.getByRole('button', { name: 'Save draft' }))
    await waitFor(() => expect(apiMocks.updateCohortExperienceConfiguration).toHaveBeenCalledWith(5, 1, expected))
  })

  it('offers no direct publishing: the saved draft goes live in Coaching, Go live', async () => {
    renderStudio()
    await screen.findByRole('button', { name: 'Save draft' })
    expect(screen.queryByRole('button', { name: /Publish|Preview/ })).toBeNull()
    expect(screen.getByText('Review these saved choices in Go live before your people receive them.')).toBeTruthy()
  })

  it('says why a viewer cannot change the tools', async () => {
    apiMocks.fetchCohortExperienceConfiguration.mockResolvedValue({ ...household, permissions: { edit: false, review: false, publish: false, rollback: false } })
    renderStudio()
    await screen.findByRole('button', { name: 'Save draft' })
    expect(screen.getByText('Your role can see these tools but can’t change them.')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Save draft' })).toHaveProperty('disabled', true)
    expect(screen.getByRole('switch', { name: 'Include Budget' })).toHaveProperty('disabled', true)
  })

  it('says a finished group is read-only without blaming the person’s role', async () => {
    apiMocks.fetchCohortExperienceConfiguration.mockResolvedValue({ ...household, cohort: { ...household.cohort, status: 'completed' }, permissions: { edit: false, review: false, publish: false, rollback: false } })
    renderStudio()
    expect(await screen.findByText('Finished and archived groups are read-only.')).toBeTruthy()
    expect(screen.queryByText('Your role can see these tools but can’t change them.')).toBeNull()
  })
})

describe('CohortExperienceStudio earlier versions', () => {
  const version = (id: number, number: number) => ({ id, number, digest: `d${id}`, published_at: '2026-10-01T00:00:00Z', published_by: { id: 1, full_name: 'Mrs. Mel' } })
  const published = (permissions = { edit: true, review: true, publish: true, rollback: true }) => ({ ...household, published_version: version(2, 2), versions: [version(2, 2), version(1, 1)], permissions }) as CohortExperienceConfiguration

  it('goes back to an earlier version after asking, and says what came of it', async () => {
    const user = userEvent.setup()
    const confirmAction = vi.spyOn(window, 'confirm').mockReturnValue(true)
    apiMocks.fetchCohortExperienceConfiguration.mockResolvedValue(published())
    apiMocks.rollbackCohortExperienceConfiguration.mockResolvedValue({ experience_configuration: published(), published_version: version(3, 3) })
    renderStudio()
    await user.click(await screen.findByText('Earlier versions (2)'))
    expect(screen.getByText('Current')).toBeTruthy()
    await user.click(screen.getByRole('button', { name: 'Go back to this version' }))
    await waitFor(() => expect(apiMocks.rollbackCohortExperienceConfiguration).toHaveBeenCalledWith(5, 1, { draft_revision: 1, expected_published_version_id: 2 }))
    expect(await screen.findByText('Version 1 is back, saved as version 3.')).toBeTruthy()
    confirmAction.mockRestore()
  })

  it('does not go back when the person says not yet', async () => {
    const user = userEvent.setup()
    vi.spyOn(window, 'confirm').mockReturnValue(false)
    apiMocks.fetchCohortExperienceConfiguration.mockResolvedValue(published())
    renderStudio()
    await user.click(await screen.findByText('Earlier versions (2)'))
    await user.click(screen.getByRole('button', { name: 'Go back to this version' }))
    expect(apiMocks.rollbackCohortExperienceConfiguration).not.toHaveBeenCalled()
  })

  it('tells an editor who can go back, and keeps the button off', async () => {
    const user = userEvent.setup()
    apiMocks.fetchCohortExperienceConfiguration.mockResolvedValue(published({ edit: true, review: false, publish: false, rollback: false }))
    renderStudio()
    await user.click(await screen.findByText('Earlier versions (2)'))
    expect(screen.getByRole('button', { name: 'Go back to this version' })).toHaveProperty('disabled', true)
    expect(screen.getByText('A program owner or reviewer can go back to an earlier version.')).toBeTruthy()
  })

  it('shows a failed restore plainly and leaves the versions as they were', async () => {
    const user = userEvent.setup()
    vi.spyOn(window, 'confirm').mockReturnValue(true)
    apiMocks.fetchCohortExperienceConfiguration.mockResolvedValue(published())
    apiMocks.rollbackCohortExperienceConfiguration.mockRejectedValue(new Error('This group changed. Reload it first.'))
    renderStudio()
    await user.click(await screen.findByText('Earlier versions (2)'))
    await user.click(screen.getByRole('button', { name: 'Go back to this version' }))
    expect((await screen.findByRole('alert')).textContent).toContain('This group changed. Reload it first.')
  })
})
