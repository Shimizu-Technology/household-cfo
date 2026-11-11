// @vitest-environment jsdom

import { cleanup, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AdminPersonaAssignableCohort, CohortExperienceConfiguration } from '../api'
import { CohortExperienceStudio } from './CohortExperienceStudio'

const apiMocks = vi.hoisted(() => ({
  fetchCohortExperienceConfiguration: vi.fn(),
  updateCohortExperienceConfiguration: vi.fn(),
  previewCohortExperienceConfiguration: vi.fn(),
  publishCohortExperienceConfiguration: vi.fn(),
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

  it('the exact preview uses the savings navigation and names the experience', async () => {
    const user = userEvent.setup()
    const savings = configuration({ schema_version: 3, experience_mode: 'savings_challenge', optional_modules: { cfo_filter: false, optionality: false } })
    apiMocks.fetchCohortExperienceConfiguration.mockResolvedValue(savings)
    apiMocks.previewCohortExperienceConfiguration.mockResolvedValue({
      experience_configuration: { ...savings, preview: { digest: 'd', draft_revision: 1, generated_at: '2026-10-17' }, preview_required: false },
      preview: { digest: 'd', draft_revision: 1, generated_at: '2026-10-17', modules: [
        { id: 'home', label: 'Home', core: true, enabled: true }, { id: 'review', label: 'Review', core: true, enabled: true },
        { id: 'ask_mia', label: 'Ask Mia', core: true, enabled: true }, { id: 'budget', label: 'Budget', core: true, enabled: true },
        { id: 'profile', label: 'My Profile', core: true, enabled: true }, { id: 'wealth', label: 'Wealth', core: true, enabled: true },
        { id: 'cfo_filter', label: 'CFO Filter', core: false, enabled: false },
      ] },
    })
    renderStudio()
    await user.click(await screen.findByRole('button', { name: 'Preview navigation' }))
    const phone = await screen.findByLabelText('Phone preview')
    expect(within(phone).getByText('Savings')).toBeTruthy()
    expect(within(phone).getByText('Statements')).toBeTruthy()
    expect(screen.getByText('90-day Savings Challenge', { selector: 'p.experience-preview-mode' })).toBeTruthy()
  })
  it('requires a fresh local preview even when the server previously previewed the saved choices', async () => {
    apiMocks.fetchCohortExperienceConfiguration.mockResolvedValue({ ...household, preview_required: false, preview: { digest: 'previous', draft_revision: 1, generated_at: '2026-10-22' } })
    renderStudio()
    await screen.findByRole('button', { name: 'Publish tool version' })
    expect(screen.getByText('Preview required')).toBeTruthy()
    expect(screen.getByText('Preview navigation to enable publishing.')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Publish tool version' })).toHaveProperty('disabled', true)
    expect(screen.getByRole('switch', { name: 'Include Budget' })).toBeTruthy()
    expect(screen.getByText('Tool choices saved. Change a choice to save again.')).toBeTruthy()
  })

  it('explains role restrictions before asking a viewer to preview or publish', async () => {
    apiMocks.fetchCohortExperienceConfiguration.mockResolvedValue({ ...household, permissions: { edit: false, review: false, publish: false, rollback: false } })
    renderStudio()
    await screen.findByRole('button', { name: 'Publish tool version' })
    expect(screen.getByText('Your role cannot save changes to these tools.')).toBeTruthy()
    expect(screen.getByText('A program editor, reviewer, or owner must preview these tools.')).toBeTruthy()
    expect(screen.getByText(/This group or your program role does not allow publishing/)).toBeTruthy()
  })

  it('explains closed-group restrictions without blaming the owner’s role', async () => {
    apiMocks.fetchCohortExperienceConfiguration.mockResolvedValue({ ...household, cohort: { ...household.cohort, status: 'completed' }, permissions: { edit: false, review: false, publish: false, rollback: false } })
    renderStudio()
    await screen.findByRole('button', { name: 'Publish tool version' })
    expect(screen.getByText('Read-only group')).toBeTruthy()
    expect(screen.queryByText('Preview required')).toBeNull()
    expect(screen.getByText('Completed and archived groups are read-only. Their tools cannot be saved, previewed, or published.')).toBeTruthy()
    for (const name of ['Save draft', 'Preview navigation', 'Publish tool version']) {
      expect(screen.getByRole('button', { name })).toHaveProperty('disabled', true)
      expect(screen.getByRole('button', { name }).getAttribute('aria-describedby')).toBe('experience-closed-help')
    }
    expect(screen.queryByText('Your role cannot save changes to these tools.')).toBeNull()
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

  it('previews the saved custom order without promoting default tabs', async () => {
    const user = userEvent.setup()
    const custom = configuration({ schema_version: 4, experience_mode: 'household_cfo', module_order: ['statements', 'ask_mia', 'home'], optional_modules: {
      review: false, budget: false, profile: false, statements: true, wealth: false, cfo_filter: false, optionality: false,
    } })
    apiMocks.fetchCohortExperienceConfiguration.mockResolvedValue(custom)
    apiMocks.previewCohortExperienceConfiguration.mockResolvedValue({
      experience_configuration: { ...custom, preview: { digest: 'd', draft_revision: 1, generated_at: '2026-11-02' } },
      preview: { digest: 'd', draft_revision: 1, generated_at: '2026-11-02', module_order: custom.draft.module_order, modules: [
        { id: 'statements', label: 'Statements', core: false, enabled: true },
        { id: 'ask_mia', label: 'Ask Mia', core: true, enabled: true },
        { id: 'home', label: 'Home', core: true, enabled: true },
      ] },
    })
    renderStudio()
    await user.click(await screen.findByRole('button', { name: 'Preview navigation' }))
    const phone = await screen.findByLabelText('Phone preview')
    expect(within(phone).getAllByText(/Statements|Ask Mia|Home/, { selector: 'b' }).map(item => item.textContent)).toEqual(['Statements', 'Ask Mia', 'Home'])
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

})
