// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AdminPersonaDetail, CurrentUser, PersonaConfiguration } from '../api'
import { CoachStudio } from './CoachStudio'
const mocks = vi.hoisted(() => ({ fetchAdminPersonas: vi.fn(), fetchAdminPersona: vi.fn(), fetchAdminPersonaAssignableCohorts: vi.fn() }))
vi.mock('../api', async (original) => ({ ...await original<typeof import('../api')>(), ...mocks }))
const supportMocks = vi.hoisted(() => ({ fetchSetupSupportRequests: vi.fn(), updateSetupSupportRequest: vi.fn() }))
vi.mock('../setupHelpApi', () => supportMocks)
vi.mock('../contexts/authContextValue', () => ({ useAuthContext: () => ({ activeCoachWorkspaceId: 2, selectCoachWorkspace: vi.fn() }) }))
vi.mock('./CoachGroupsParticipants', () => ({ CoachGroupsParticipants: () => <section>Participant access task</section> }))
vi.mock('./CoachChallengeDashboard', () => ({ CoachChallengeDashboard: () => <section>Daily check-ins task</section> }))
vi.mock('./CoachContentLibrary', () => ({ CoachContentLibrary: () => null, PersonaContentPacksPanel: () => <section>Exact approved sources</section> }))
vi.mock('./PersonaReleasePanel', () => ({ PersonaReleasePanel: ({ dirty }: { dirty: boolean }) => <section><button disabled={dirty}>Publish reviewed assistant</button></section> }))
const personaConfiguration = {
  version: 1 as const,
  identity: {
    assistant_name: 'Coach Lani', human_coach_name: 'Mrs. Mel', human_coach_title: 'Financial coach',
    assistant_relationship: "A digital coaching assistant that applies the human coach's approved teaching without impersonating the human coach.",
    disclosure: "Be clear that this is a digital assistant guided by the human coach's published approach.",
    audience: "People participating in Mrs. Mel's financial education program.", client_term: 'participant',
  },
  voice: {
    tone_traits: ['warm', 'direct', 'respectful'], energy: 'Calm and focused.',
    accountability_style: "Name choices and patterns clearly while protecting the participant's dignity.",
    language_style: ['Use plain language.', 'Keep the next step concrete.'],
  },
  coaching: {
    philosophy: 'Help the participant understand the decision and make one practical move at a time.',
    method: 'Answer the direct question, explain the reasoning, and identify one useful next step.',
    principles: ["Use the participant's confirmed information.", 'Coach decisions and patterns without shame.'],
    do: [], do_not: [],
  },
  culture: {
    locale_label: 'No locale selected',
    context: 'Use only cultural and community context explicitly approved by the human coach.',
    local_realities: [], references: [],
  },
  phrases: [],
  curriculum: { guidance: [], scripts: [], examples: [] },
  response_shape: {
    min_sentences: 2, max_sentences: 5, max_characters: 1500,
    plain_text_only: true, validate_before_coaching: true, next_move_required: true,
  },
}

const persona = { id: 81, name: 'Coach Lani', description: 'Private draft', status: 'draft', draft_revision: 1, draft: personaConfiguration as PersonaConfiguration, published_version: null, visible_assignment_count: 0, has_unpublished_changes: true, permissions: { read: true, edit: true, publish: true, assign: true, archive: true, restore: false }, guardrails: { rules: ['Financial and privacy policy remains locked.'] }, versions: [], assignments: [], approved_phrase_promotions: [], phrase_artifact_access: { can_add: true, artifacts: [] } } as unknown as AdminPersonaDetail
const actor = { id: 10, is_admin: false, full_name: 'Fictional coach', coach_workspaces: [{ id: 2, name: 'Mel coaching', membership_role: 'owner' }] } as CurrentUser
beforeEach(() => { vi.clearAllMocks(); supportMocks.fetchSetupSupportRequests.mockReset(); supportMocks.updateSetupSupportRequest.mockReset(); mocks.fetchAdminPersonas.mockResolvedValue([persona]); mocks.fetchAdminPersona.mockResolvedValue(persona); mocks.fetchAdminPersonaAssignableCohorts.mockResolvedValue([]); Element.prototype.scrollIntoView = vi.fn(); window.scrollTo = vi.fn() })
afterEach(cleanup)
describe('coach daily operation and assistant workflow', () => {
  it('opens setup support only on demand in the selected group and holds workspace tabs during triage', async () => {
    mocks.fetchAdminPersonaAssignableCohorts.mockResolvedValue([{ id: 41, name: 'BOG challenge group', status: 'enrolling', assignable: true, blocked_reason: null, persona_assignment: null }])
    const record = { id: 91, participant_name: 'Support participant', program_name: 'BOG', status: 'requested', reason_label: 'Practice numbers', lock_version: 2, created_at: '2026-10-07T10:00:00Z', permissions: { triage: true, prepare: false, decline: true } }
    supportMocks.fetchSetupSupportRequests.mockResolvedValue({ records: [record], next_cursor: null })
    let complete!: (value: unknown) => void
    supportMocks.updateSetupSupportRequest.mockReturnValue(new Promise((resolve) => { complete = resolve }))
    render(<CoachStudio currentUser={actor} onDirtyChange={() => undefined} />)
    await screen.findByLabelText('Group')
    expect(supportMocks.fetchSetupSupportRequests).not.toHaveBeenCalled()
    const disclosure = screen.getByRole('button', { name: 'Setup help requests' })
    expect(disclosure.getAttribute('aria-expanded')).toBe('false')
    fireEvent.click(disclosure)
    await screen.findByText('Support participant')
    expect(supportMocks.fetchSetupSupportRequests).toHaveBeenCalledWith(41, null, expect.any(AbortSignal))
    expect(screen.queryByRole('button', { name: 'Prepare participant review' })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Mark in review' }))
    expect(screen.getByRole('tab', { name: /Assistant voice/ })).toHaveProperty('disabled', true)
    expect(screen.getByLabelText('Group')).toHaveProperty('disabled', true)
    expect(disclosure).toHaveProperty('disabled', true)
    complete({ request: { ...record, status: 'in_review', lock_version: 3 } })
    await screen.findByText('Request #91: In review.')
    await waitFor(() => expect(screen.getByRole('tab', { name: /Assistant voice/ })).toHaveProperty('disabled', false))
    fireEvent.click(disclosure)
    expect(screen.queryByText('Support participant')).toBeNull()
  })
  it('starts with participant operations and keeps assistant construction secondary', async () => {
    render(<CoachStudio currentUser={actor} onDirtyChange={() => undefined} />)
    await screen.findByText('Daily check-ins task')
    expect(screen.getByRole('tab', { name: /Daily coaching/ }).getAttribute('aria-selected')).toBe('true')
    expect(screen.queryByLabelText('Assistant name')).toBeNull()
    expect(screen.queryByText(/Shape a coaching assistant people can trust/)).toBeNull()
  })
  it('shows a cohort loading failure and retries from Daily coaching without opening assistant construction', async () => {
    mocks.fetchAdminPersonaAssignableCohorts.mockRejectedValueOnce(new Error('Cohort list temporarily unavailable'))
    mocks.fetchAdminPersonaAssignableCohorts.mockResolvedValue([{ id: 41, name: 'BOG challenge group', status: 'enrolling', assignable: true, blocked_reason: null, persona_assignment: null }])
    render(<CoachStudio currentUser={actor} onDirtyChange={() => undefined} />)
    const alert = await screen.findByRole('alert')
    expect(alert.textContent).toContain('Cohort list temporarily unavailable')
    expect(alert.closest('[role="tabpanel"]')).toBeNull()
    expect(screen.getByRole('tab', { name: /Daily coaching/ }).getAttribute('aria-selected')).toBe('true')
    expect(screen.queryByLabelText('Group')).toBeNull()
    expect(screen.queryByLabelText('Assistant name')).toBeNull()
    fireEvent.click(within(alert).getByRole('button', { name: 'Retry' }))
    await screen.findByLabelText('Group')
    await waitFor(() => expect(screen.getByLabelText('Group')).toHaveProperty('disabled', false))
    expect(screen.getByLabelText('Group')).toHaveProperty('value', '41')
    expect(screen.queryByRole('alert')).toBeNull()
    expect(mocks.fetchAdminPersonaAssignableCohorts).toHaveBeenCalledTimes(2)
    expect(screen.getByRole('tab', { name: /Daily coaching/ }).getAttribute('aria-selected')).toBe('true')
    expect(screen.queryByLabelText('Assistant name')).toBeNull()
  })
  it('preserves unsaved draft fields while visiting sources and blocked publication', async () => {
    const dirty = vi.fn()
    render(<CoachStudio currentUser={actor} onDirtyChange={dirty} />)
    fireEvent.click(screen.getByRole('tab', { name: /Assistant voice/ }))
    const name = await screen.findByLabelText('Assistant name')
    fireEvent.change(name, { target: { value: 'Unfinished coaching voice' } })
    fireEvent.click(screen.getByRole('button', { name: 'Sources' }))
    expect(name.closest('[hidden]')).toBeTruthy()
    expect(screen.getByText('Exact approved sources').closest('[hidden]')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Evaluate & publish' }))
    expect(screen.getByRole('button', { name: 'Publish reviewed assistant' })).toHaveProperty('disabled', true)
    fireEvent.click(within(screen.getByRole('navigation', { name: 'Assistant workflow' })).getByRole('button', { name: 'Draft' }))
    expect(screen.getByLabelText('Assistant name')).toHaveProperty('value', 'Unfinished coaching voice')
    expect(dirty).toHaveBeenLastCalledWith(true)
  })
})
