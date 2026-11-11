// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError, type AdminPersonaDetail, type CurrentUser, type PersonaConfiguration } from '../api'
import { CoachStudioAdvanced as CoachStudio } from './CoachStudioAdvanced'
const mocks = vi.hoisted(() => ({ fetchAdminPersonas: vi.fn(), fetchAdminPersona: vi.fn(), fetchAdminPersonaAssignableCohorts: vi.fn(), updateAdminPersona: vi.fn() }))
vi.mock('../api', async (original) => ({ ...await original<typeof import('../api')>(), ...mocks }))
const supportMocks = vi.hoisted(() => ({ fetchSetupSupportRequests: vi.fn(), updateSetupSupportRequest: vi.fn() }))
vi.mock('../setupHelpApi', () => supportMocks)
vi.mock('../contexts/authContextValue', () => ({ useAuthContext: () => ({ activeCoachWorkspaceId: 2, selectCoachWorkspace: vi.fn() }) }))
vi.mock('./CoachGroupsParticipants', () => ({ CoachGroupsParticipants: ({ onDirtyChange, onGroupsChanged }: { onDirtyChange: (dirty: boolean) => void; onGroupsChanged: () => void }) => <section>Participant access task<input aria-label="Unsent participant invitation" onChange={(event) => onDirtyChange(Boolean(event.target.value))} /><button onClick={onGroupsChanged}>Finish group change</button></section> }))
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
beforeEach(() => { vi.resetAllMocks(); supportMocks.fetchSetupSupportRequests.mockReset(); supportMocks.updateSetupSupportRequest.mockReset(); mocks.fetchAdminPersonas.mockResolvedValue([persona]); mocks.fetchAdminPersona.mockResolvedValue(persona); mocks.fetchAdminPersonaAssignableCohorts.mockResolvedValue([]); Element.prototype.scrollIntoView = vi.fn(); window.scrollTo = vi.fn() })
afterEach(cleanup)
describe('coach daily operation and assistant workflow', () => {
  it('tells an editor why Assign is disabled and links the reason to the button', async () => {
    const published = { ...persona, status: 'published', has_unpublished_changes: false, published_version: { id: 1, number: 1 }, permissions: { ...persona.permissions, assign: false } } as unknown as AdminPersonaDetail
    mocks.fetchAdminPersonas.mockResolvedValue([published]); mocks.fetchAdminPersona.mockResolvedValue(published)
    mocks.fetchAdminPersonaAssignableCohorts.mockResolvedValue([{ id: 41, name: 'BOG challenge group', status: 'enrolling', assignable: true, blocked_reason: null, persona_assignment: null }])
    render(<CoachStudio currentUser={actor} onDirtyChange={() => undefined} />)
    await waitFor(() => expect(mocks.fetchAdminPersonaAssignableCohorts).toHaveBeenCalledTimes(1))
    fireEvent.click(screen.getByRole('tab', { name: /Voice versions/ }))
    await screen.findByLabelText('Assistant name')
    fireEvent.click(screen.getByRole('button', { name: 'Assign' }))
    const assign = (await screen.findByText('BOG challenge group')).closest('article')!.querySelector('button')!
    expect(assign.textContent).toBe('Assign')
    expect(assign).toHaveProperty('disabled', true)
    expect(document.getElementById(assign.getAttribute('aria-describedby') ?? '')?.textContent).toContain('Ask a program owner')
  })
  it('loads assistant details on first voice visit and reuses them after a clean tab transition', async () => {
    render(<CoachStudio currentUser={actor} onDirtyChange={() => undefined} />)
    await waitFor(() => expect(mocks.fetchAdminPersonaAssignableCohorts).toHaveBeenCalledTimes(1))
    fireEvent.click(screen.getByRole('tab', { name: /Voice versions/ }))
    await screen.findByLabelText('Assistant name')
    expect(mocks.fetchAdminPersonas).toHaveBeenCalledTimes(1)
    expect(mocks.fetchAdminPersona).toHaveBeenCalledTimes(1)
    fireEvent.click(screen.getByRole('tab', { name: /Group updates/ }))
    fireEvent.click(screen.getByRole('tab', { name: /Voice versions/ }))
    await screen.findByLabelText('Assistant name')
    expect(mocks.fetchAdminPersonas).toHaveBeenCalledTimes(1)
    expect(mocks.fetchAdminPersona).toHaveBeenCalledTimes(1)
  })
  it('loads the selected assistant when the Coaching Library is visited first', async () => {
    render(<CoachStudio currentUser={actor} onDirtyChange={() => undefined} />)
    fireEvent.click(screen.getByRole('tab', { name: /Teaching library/ }))
    await waitFor(() => expect(mocks.fetchAdminPersona).toHaveBeenCalledWith(81))
    expect(mocks.fetchAdminPersonas).toHaveBeenCalledTimes(1)
  })
  it('refreshes a failed cached list on section revisit after a detail reload clears its error', async () => {
    const second = { ...persona, id: 82, name: 'Second assistant' }
    const newest = { ...persona, id: 83, name: 'Newest assistant' }
    mocks.fetchAdminPersonas.mockResolvedValue([persona, second, newest])
    mocks.fetchAdminPersonas.mockResolvedValueOnce([persona, second])
    mocks.fetchAdminPersonas.mockRejectedValueOnce(new Error('Assistant list refresh failed'))
    mocks.fetchAdminPersona.mockResolvedValueOnce(persona)
    mocks.fetchAdminPersona.mockRejectedValueOnce(new Error('Second assistant detail failed'))
    render(<CoachStudio currentUser={actor} onDirtyChange={() => undefined} />)
    fireEvent.click(screen.getByRole('tab', { name: /Voice versions/ }))
    await screen.findByLabelText('Assistant name')
    fireEvent.click(screen.getByRole('button', { name: /^Second assistant/ }))
    const detailAlert = await screen.findByRole('alert')
    expect(detailAlert.textContent).toContain('Second assistant detail failed')
    fireEvent.click(within(detailAlert).getByRole('button', { name: 'Retry' }))
    await screen.findByText('Assistant list refresh failed')
    expect(mocks.fetchAdminPersonas).toHaveBeenCalledTimes(2)
    expect(screen.queryByRole('button', { name: /^Newest assistant/ })).toBeNull()
    fireEvent.change(screen.getByLabelText('Assistant name'), { target: { value: 'Unsaved name' } })
    fireEvent.click(screen.getByRole('button', { name: /^Second assistant/ }))
    fireEvent.click(screen.getByRole('button', { name: 'Reload server draft' }))
    await waitFor(() => expect(screen.queryByRole('alert')).toBeNull())
    await waitFor(() => expect(screen.getByLabelText('Assistant name')).toHaveProperty('value', 'Coach Lani'))
    // Clearing a detail error does not trigger an automatic list retry loop.
    expect(mocks.fetchAdminPersonas).toHaveBeenCalledTimes(2)
    fireEvent.click(screen.getByRole('tab', { name: /Group updates/ }))
    fireEvent.click(screen.getByRole('tab', { name: /Voice versions/ }))
    await screen.findByRole('button', { name: /^Newest assistant/ })
    expect(mocks.fetchAdminPersonas).toHaveBeenCalledTimes(3)
  })
  it('preserves unsaved draft fields while visiting sources and blocked publication', async () => {
    const dirty = vi.fn()
    render(<CoachStudio currentUser={actor} onDirtyChange={dirty} />)
    fireEvent.click(screen.getByRole('tab', { name: /Voice versions/ }))
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

describe('reviewed suggestion handoff into the detailed form', () => {
  const proposal = { description: 'Private source-assistant suggestion', draft_config: persona.draft!, personaId: 81, workspaceId: 2, draftRevision: 1 }
  it('loads the source assistant even when another assistant moves ahead in the library', async () => {
    const other = { ...persona, id: 82, name: 'Another assistant' }
    mocks.fetchAdminPersonas.mockResolvedValue([other, persona])
    mocks.fetchAdminPersona.mockImplementation(async (id: number) => id === 81 ? persona : other)
    render(<CoachStudio currentUser={actor} onDirtyChange={() => undefined} initialSection="assistants" proposedState={proposal} />)
    await screen.findByDisplayValue(proposal.description)
    expect(mocks.fetchAdminPersona).toHaveBeenCalledWith(81)
    expect(mocks.fetchAdminPersona).not.toHaveBeenCalledWith(82)
    expect(screen.getByLabelText('Assistant name')).toHaveProperty('value', 'Coach Lani')
  })
  it.each(['revision', 'program'])('does not copy private suggestions after the source %s changes', async (changed) => {
    if (changed === 'revision') mocks.fetchAdminPersona.mockResolvedValue({ ...persona, draft_revision: 2 })
    render(<CoachStudio currentUser={actor} onDirtyChange={() => undefined} initialSection="assistants" proposedState={changed === 'program' ? { ...proposal, workspaceId: 3 } : proposal} />)
    await screen.findByText('Your assistant or program changed. Open its latest suggestions before copying them into the form.')
    expect(screen.queryByDisplayValue(proposal.description)).toBeNull()
    expect(mocks.fetchAdminPersona).toHaveBeenCalledWith(81)
  })
})

it('CR18 advanced saves require confirmation before discarding other coach suggestions',async()=>{
 const confirm=vi.spyOn(window,'confirm').mockReturnValue(true)
 mocks.updateAdminPersona.mockRejectedValueOnce(new ApiRequestError('Pending suggestions need review.',{status:422,code:'persona_pending_suggestions'})).mockResolvedValueOnce({...persona,draft_revision:2})
 render(<CoachStudio currentUser={actor} onDirtyChange={vi.fn()} initialSection="assistants"/>)
 const name=await screen.findByLabelText('Assistant name');fireEvent.change(name,{target:{value:'A changed assistant'}})
 const save=screen.getByRole('button',{name:/^Save draft$/});await waitFor(()=>expect(save).toHaveProperty('disabled',false));fireEvent.click(save)
 await waitFor(()=>expect(mocks.updateAdminPersona).toHaveBeenCalledTimes(2))
 expect(confirm).toHaveBeenCalledWith(expect.stringContaining('another coach'))
 expect(mocks.updateAdminPersona.mock.calls[1][1].discard_pending_suggestions).toBe(true)
 confirm.mockRestore()
})
