// @vitest-environment jsdom

import { useState } from 'react'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError, type AdminPersonaDetail, type AdminPersonaSetupSession, type PersonaConfiguration } from '../api'
import { PersonaSetupChat } from './PersonaSetupChat'
import { useCoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

const apiMocks = vi.hoisted(() => ({
  readCoachVoiceTranscript: vi.fn(),
  createAdminPersonaSetupSession: vi.fn(),
  createAdminPersonaSetupTurn: vi.fn(),
  rebaseAdminPersonaSetupSession: vi.fn(),
  abandonAdminPersonaSetupSession: vi.fn(),
  resolveAdminPersonaSetupProposal: vi.fn(),
}))

vi.mock('../enterpriseApi',()=>({readCoachVoiceTranscript:apiMocks.readCoachVoiceTranscript}))

vi.mock('../api', async (importOriginal) => ({
  ...await importOriginal<typeof import('../api')>(),
  ...apiMocks,
}))

const authoringState: { description: string; draft_config: PersonaConfiguration } = {
  description: 'Warm coach',
  draft_config: { identity: { assistant_name: 'Mia' } } as unknown as PersonaConfiguration,
}

function session(overrides: Partial<AdminPersonaSetupSession> = {}): AdminPersonaSetupSession {
  return {
    id: 51,
    persona_id: 81,
    workspace_id: 1,
    status: 'active',
    base_draft_revision: 1,
    base_config_digest: 'abc',
    last_activity_at: '2026-10-02T00:00:00Z',
    stale: false,
    turns: [],
    proposal: null,
    ...overrides,
  }
}

function proposalSession(): AdminPersonaSetupSession {
  return session({
    turns: [{ id: 91, position: 1, status: 'ready', user_message: 'Her name is Mrs. Mel.', assistant_message: 'I prepared one change.', error_code: null, created_at: '2026-10-02T00:00:00Z' }],
    proposal: {
      id: 71,
      status: 'pending',
      base_draft_revision: 1,
      base_config_digest: 'abc',
      proposal_digest: 'def',
      operations: [{ op: 'set', path: 'identity.human_coach_name', value: 'Mrs. Mel', source_basis: 'coach_quote', evidence_quote: 'Her name is Mrs. Mel.' }],
      before_state: authoringState,
      after_state: authoringState,
      grouped_changes: [{ group: 'Identity', changes: [{ group: 'Identity', path: 'identity.human_coach_name', label: 'Human coach name', before: '', after: 'Mrs. Mel', source_basis: 'coach_quote', evidence_quote: 'Her name is Mrs. Mel.' }] }],
      created_at: '2026-10-02T00:00:00Z',
      resolved_at: null,
    },
  })
}

function persona(id = 81) {
  return { id, name: `Persona ${id}`, permissions: { edit: true } } as unknown as AdminPersonaDetail
}

function Harness({
  workspaceId = 1,
  saveAndPreview = false,
  personaId = 81,
  manualDirty = false,
  onPersonaChange = vi.fn(),
  onReviewInForm = vi.fn(),
}: {
  workspaceId?: number
  saveAndPreview?: boolean
  personaId?: number
  manualDirty?: boolean
  onPersonaChange?: (value: AdminPersonaDetail) => void
  onReviewInForm?: (value: { description: string; draft_config: PersonaConfiguration }, path: string | null) => void
}) {
  const lifecycle = useCoachWorkspaceMutationLifecycle(workspaceId)
  return <>
    <select aria-label="Workspace" disabled={lifecycle.pending} value={workspaceId} onChange={() => undefined}><option value={workspaceId}>Workspace {workspaceId}</option></select>
    <PersonaSetupChat
      key={`${workspaceId}-${personaId}`}
      persona={persona(personaId)}
      saveAndPreview={saveAndPreview}
      manualDirty={manualDirty}
      mutationLifecycle={lifecycle}
      onPersonaChange={onPersonaChange}
      onReviewInForm={onReviewInForm}
      onDirtyChange={() => undefined}
    />
  </>
}

describe('PersonaSetupChat', () => {
  beforeEach(() => {
    vi.resetAllMocks()
    apiMocks.createAdminPersonaSetupSession.mockResolvedValue(session())
  })
  afterEach(cleanup)

  it('keeps setup private and applies only a reviewed proposal', async () => {
    const onPersonaChange = vi.fn()
    apiMocks.createAdminPersonaSetupTurn.mockResolvedValue(proposalSession())
    apiMocks.resolveAdminPersonaSetupProposal.mockResolvedValue({ session: session(), persona: persona() })
    render(<Harness onPersonaChange={onPersonaChange} />)

    await screen.findByLabelText('Message Mia')
    expect(screen.getByText('Only share your own teaching, without private client details.')).toBeTruthy()
    await userEvent.click(screen.getByText('How this works', { selector: 'summary' }))
    expect(screen.getByText(/Participant household and financial data are excluded/)).toBeTruthy()
    await userEvent.type(screen.getByLabelText('Message Mia'), 'Her name is Mrs. Mel.')
    await userEvent.click(screen.getByRole('button', { name: 'Send to Mia' }))

    await userEvent.click(await screen.findByText('Review each suggestion',{selector:'summary'}))
    expect(await screen.findByText('Human coach name')).toBeTruthy()
    expect(screen.getByRole('heading', { name: 'Your voice suggestions' })).toBeTruthy()
    expect(screen.queryByText('No proposal yet.')).toBeNull()
    expect(screen.getByText('Coach said')).toBeTruthy()
    expect(screen.getAllByText('Mrs. Mel')[0]).toBeTruthy()
    expect(onPersonaChange).not.toHaveBeenCalled()

    await userEvent.click(screen.getByRole('button', { name: 'Use all suggestions' }))
    await vi.waitFor(() => expect(onPersonaChange).toHaveBeenCalledTimes(1))
    expect(apiMocks.resolveAdminPersonaSetupProposal.mock.calls[0][3]).toBe('apply')
  })

  it('focuses a newly mounted proposal after controls unlock even when animation frames are delayed', async () => {
    const frame = vi.spyOn(window, 'requestAnimationFrame').mockImplementation(() => 1)
    try {
      apiMocks.createAdminPersonaSetupTurn.mockResolvedValue(proposalSession())
      render(<Harness />)
      await userEvent.type(await screen.findByLabelText('Message Mia'), 'Her name is Mrs. Mel.')
      await userEvent.click(screen.getByRole('button', { name: 'Send to Mia' }))
      const heading = await screen.findByRole('heading', { name: 'Your voice suggestions' })
      await waitFor(() => expect(document.activeElement).toBe(heading))
      expect(screen.getByRole('button', { name: 'Use all suggestions' })).toHaveProperty('disabled', false)
    } finally { frame.mockRestore() }
  })

  it('blocks apply for manual edits and can copy the proposal into the form', async () => {
    const onReviewInForm = vi.fn()
    apiMocks.createAdminPersonaSetupSession.mockResolvedValue(proposalSession())
    render(<Harness manualDirty onReviewInForm={onReviewInForm} />)

    expect((await screen.findByRole('button', { name: 'Use all suggestions' }) as HTMLButtonElement).disabled).toBe(true)
    await userEvent.click(screen.getByRole('button', { name: 'Review in form' }))
    expect(onReviewInForm).toHaveBeenCalledWith(authoringState, 'identity.human_coach_name', 1)
  })

  it('blocks switching during a turn and ignores the delayed prior-workspace response', async () => {
    let release!: (value: AdminPersonaSetupSession) => void
    apiMocks.createAdminPersonaSetupTurn.mockReturnValue(new Promise<AdminPersonaSetupSession>((resolve) => { release = resolve }))
    const view = render(<Harness />)
    await screen.findByLabelText('Message Mia')
    await userEvent.type(screen.getByLabelText('Message Mia'), 'Use my exact words.')
    await userEvent.click(screen.getByRole('button', { name: 'Send to Mia' }))
    expect((screen.getByLabelText('Workspace') as HTMLSelectElement).disabled).toBe(true)

    view.rerender(<Harness workspaceId={2} personaId={82} />)
    release(proposalSession())
    await screen.findByText('Workspace 2')
    expect(screen.queryByText('Human coach name')).toBeNull()
  })

  it('keeps the message and idempotency key for a safe retry', async () => {
    apiMocks.createAdminPersonaSetupTurn
      .mockRejectedValueOnce(new Error('Mia took too long.'))
      .mockResolvedValueOnce(proposalSession())
    render(<Harness />)
    const composer = await screen.findByLabelText('Message Mia') as HTMLTextAreaElement
    await userEvent.type(composer, 'Her name is Mrs. Mel.')
    await userEvent.click(screen.getByRole('button', { name: 'Send to Mia' }))
    expect(await screen.findByRole('button', { name: 'Retry message' })).toBeTruthy()
    expect(composer.value).toBe('Her name is Mrs. Mel.')

    await userEvent.click(screen.getByRole('button', { name: 'Retry message' }))
    await screen.findByText('Human coach name')
    expect(apiMocks.createAdminPersonaSetupTurn.mock.calls[1][3]).toBe(apiMocks.createAdminPersonaSetupTurn.mock.calls[0][3])
  })

  it('keeps an authoritative failed turn available with a fresh request key', async () => {
    const failedSession = session({
      turns: [{
        id: 92,
        position: 1,
        status: 'failed',
        user_message: 'Use a calm voice.',
        assistant_message: 'Nothing changed. Try again.',
        error_code: 'persona_setup_unavailable',
        created_at: '2026-10-02T00:00:00Z',
      }],
    })
    apiMocks.createAdminPersonaSetupTurn
      .mockRejectedValueOnce(new ApiRequestError('HTTP 503: model unavailable', {
        status: 503,
        code: 'persona_setup_unavailable',
        payload: { session: failedSession },
      }))
      .mockResolvedValueOnce(proposalSession())
    render(<Harness />)
    const composer = await screen.findByLabelText('Message Mia') as HTMLTextAreaElement
    await userEvent.type(composer, 'Use a calm voice.')
    await userEvent.click(screen.getByRole('button', { name: 'Send to Mia' }))

    expect(await screen.findByRole('button', { name: 'Send to Mia' })).toBeTruthy()
    expect(composer.value).toBe('Use a calm voice.')
    expect(screen.getByRole('alert').textContent).toContain('Nothing changed. Try again or use Guided setup.')
    expect(screen.getByRole('alert').textContent).not.toContain('503')

    await userEvent.click(screen.getByRole('button', { name: 'Send to Mia' }))
    await screen.findByText('Human coach name')
    expect(apiMocks.createAdminPersonaSetupTurn.mock.calls[1][3]).not.toBe(apiMocks.createAdminPersonaSetupTurn.mock.calls[0][3])
  })

  it('shows a ready clarification as a reply without errors or empty Apply controls', async () => {
    const clarification = 'Which part of the voice would you like to change?'
    apiMocks.createAdminPersonaSetupTurn.mockResolvedValue(session({
      turns: [{ id: 94, position: 1, status: 'ready', user_message: 'Make Mia warmer.', assistant_message: clarification, error_code: null, created_at: '2026-10-02T00:00:00Z' }],
    }))
    render(<Harness />)
    const composer = await screen.findByLabelText('Message Mia') as HTMLTextAreaElement
    await userEvent.type(composer, 'Make Mia warmer.')
    await userEvent.click(screen.getByRole('button', { name: 'Send to Mia' }))

    expect(await screen.findByText(clarification)).toBeTruthy()
    expect(screen.queryByRole('alert')).toBeNull()
    expect(screen.queryByRole('button', { name: 'Use all suggestions' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Review in form' })).toBeNull()
    expect(screen.queryByText('No proposal yet.')).toBeNull()
    expect(screen.queryByRole('heading', { name: 'Your voice suggestions' })).toBeNull()
    expect(composer.value).toBe('')
    expect(screen.queryByRole('button', { name: 'Retry message' })).toBeNull()
    await userEvent.type(composer, 'Ask one short question at a time.')
    expect(screen.getByRole('button', { name: 'Send to Mia' })).toHaveProperty('disabled', false)
  })

  it('explains a closed chat when replacement creation fails and retries only the new session', async () => {
    apiMocks.createAdminPersonaSetupSession
      .mockResolvedValueOnce(session())
      .mockRejectedValueOnce(new ApiRequestError('HTTP 500: internal failure', { status: 500 }))
      .mockResolvedValueOnce(session({ id: 52 }))
    apiMocks.abandonAdminPersonaSetupSession.mockResolvedValue(session({ status: 'abandoned' }))
    render(<Harness />)
    await userEvent.click(await screen.findByRole('button', { name: 'Start a fresh setup chat' }))
    const explanation = await screen.findByText(/The old chat was closed, but a new chat could not be started/)
    expect(explanation.textContent).not.toContain('Nothing changed')
    expect(explanation.textContent).not.toContain('500')
    const retry = await screen.findByRole('button', { name: 'Open a fresh chat' })
    await vi.waitFor(() => expect(retry).toHaveProperty('disabled', false))
    await userEvent.click(retry)
    await vi.waitFor(() => expect(apiMocks.createAdminPersonaSetupSession).toHaveBeenCalledTimes(3))
    await vi.waitFor(() => expect(screen.getByLabelText('Message Mia')).toHaveProperty('disabled', false))
    expect(apiMocks.abandonAdminPersonaSetupSession).toHaveBeenCalledTimes(1)
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('uses close-specific wording when abandoning the chat fails', async () => {
    apiMocks.abandonAdminPersonaSetupSession.mockRejectedValue(new ApiRequestError('HTTP 500', { status: 500 }))
    render(<Harness />)
    await userEvent.click(await screen.findByRole('button', { name: 'Start a fresh setup chat' }))
    expect((await screen.findByRole('alert')).textContent).toBe('The setup chat could not be closed. Try again.')
    expect(apiMocks.createAdminPersonaSetupSession).toHaveBeenCalledTimes(1)
  })

  it('uses action-specific wording for an unconfirmed proposal apply error', async () => {
    apiMocks.createAdminPersonaSetupSession.mockResolvedValue(proposalSession())
    apiMocks.resolveAdminPersonaSetupProposal.mockRejectedValue(new ApiRequestError('HTTP 500', { status: 500 }))
    render(<Harness />)
    await userEvent.click(await screen.findByRole('button', { name: 'Use all suggestions' }))
    expect((await screen.findByRole('alert')).textContent).toBe('The proposal could not be saved.')
  })

  it('reuses a proposal action key after a lost response', async () => {
    apiMocks.createAdminPersonaSetupSession.mockResolvedValue(proposalSession())
    apiMocks.resolveAdminPersonaSetupProposal
      .mockRejectedValueOnce(new Error('The response was lost.'))
      .mockResolvedValueOnce({ session: session(), persona: persona() })
    render(<Harness />)

    await userEvent.click(await screen.findByRole('button', { name: 'Use all suggestions' }))
    expect((await screen.findByRole('alert')).textContent).toContain('The response was lost.')
    await userEvent.click(screen.getByRole('button', { name: 'Use all suggestions' }))
    await vi.waitFor(() => expect(apiMocks.resolveAdminPersonaSetupProposal).toHaveBeenCalledTimes(2))

    expect(apiMocks.resolveAdminPersonaSetupProposal.mock.calls[1][4])
      .toBe(apiMocks.resolveAdminPersonaSetupProposal.mock.calls[0][4])
  })

  it('retains separate retry keys when apply and reject both fail', async () => {
    apiMocks.createAdminPersonaSetupSession.mockResolvedValue(proposalSession())
    apiMocks.resolveAdminPersonaSetupProposal
      .mockRejectedValueOnce(new Error('The apply response was lost.'))
      .mockRejectedValueOnce(new Error('The reject response was lost.'))
      .mockResolvedValueOnce({ session: session(), persona: persona() })
    render(<Harness />)

    await userEvent.click(await screen.findByRole('button', { name: 'Use all suggestions' }))
    expect((await screen.findByRole('alert')).textContent).toContain('The apply response was lost.')
    await userEvent.click(screen.getByRole('button', { name: 'Reject proposal' }))
    expect((await screen.findByRole('alert')).textContent).toContain('The reject response was lost.')
    await userEvent.click(screen.getByRole('button', { name: 'Use all suggestions' }))
    await vi.waitFor(() => expect(apiMocks.resolveAdminPersonaSetupProposal).toHaveBeenCalledTimes(3))

    const calls = apiMocks.resolveAdminPersonaSetupProposal.mock.calls
    expect(calls[2][4]).toBe(calls[0][4])
    expect(calls[1][4]).not.toBe(calls[0][4])
  })

  it('shows a real retry path when the setup session cannot be loaded', async () => {
    apiMocks.createAdminPersonaSetupSession
      .mockRejectedValueOnce(new Error('Network unavailable.'))
      .mockResolvedValueOnce(session())
    render(<Harness />)

    await userEvent.click(await screen.findByRole('button', { name: 'Try again' }))

    expect(await screen.findByLabelText('Message Mia')).toBeTruthy()
    expect(apiMocks.createAdminPersonaSetupSession).toHaveBeenCalledTimes(2)
  })

  it('opens a fresh session from an inactive chat without using load recovery', async () => {
    apiMocks.createAdminPersonaSetupSession
      .mockResolvedValueOnce(session({ status: 'completed' }))
      .mockResolvedValueOnce(session({ id: 52 }))
    render(<Harness />)

    await userEvent.click(await screen.findByRole('button', { name: 'Open a fresh chat' }))

    expect(await screen.findByLabelText('Message Mia')).toBeTruthy()
    expect(apiMocks.createAdminPersonaSetupSession).toHaveBeenCalledTimes(2)
    expect(apiMocks.abandonAdminPersonaSetupSession).not.toHaveBeenCalled()
    expect(screen.queryByRole('button', { name: 'Try again' })).toBeNull()
  })

  it('renders a null assistant message from a processing turn', async () => {
    apiMocks.createAdminPersonaSetupSession.mockResolvedValue(session({
      turns: [{
        id: 93,
        position: 1,
        status: 'processing',
        user_message: 'Use a calm voice.',
        assistant_message: null,
        error_code: null,
        created_at: '2026-10-02T00:00:00Z',
      }],
    }))
    render(<Harness />)

    expect(await screen.findByText('Mia is still preparing this proposal.')).toBeTruthy()
  })
 it('keeps the simple proposal focused on suggested wording while retaining original evidence', async () => {
   apiMocks.createAdminPersonaSetupSession.mockResolvedValue(proposalSession())
   render(<Harness saveAndPreview />)
   await screen.findByRole('button', { name: 'Use all suggestions' })
   expect(screen.getByText('Review each suggestion',{selector:'summary'}).closest('details')?.open).toBe(false)
   await userEvent.click(screen.getByText('Review each suggestion',{selector:'summary'}))
   await waitFor(() => expect(screen.getByRole('checkbox', { name: 'Use this human coach name suggestion' })).toHaveProperty('checked', true))
   expect(screen.queryByText('After')).toBeNull()
   expect(screen.getByText('Original wording and source')).toBeTruthy()
 })

  it('saves chosen operation indexes and transitions into the preview through onPersonaChange',async()=>{
    const proposed=proposalSession()
    proposed.proposal!.operations.unshift({op:'set',path:'response_shape.max_sentences',value:3,source_basis:'coach_quote',evidence_quote:'3'})
    proposed.proposal!.grouped_changes.push({group:'Response',changes:[{group:'Response',path:'response_shape.max_sentences',label:'Max sentences',before:5,after:3,source_basis:'coach_quote',evidence_quote:'3'}]})
    apiMocks.createAdminPersonaSetupSession.mockResolvedValue(proposed)
    apiMocks.resolveAdminPersonaSetupProposal.mockResolvedValue({session:session(),persona:persona()})
    const changed=vi.fn(),review=vi.fn()
    function Transition(){const [saved,setSaved]=useState<AdminPersonaDetail|null>(null);return saved ? <p>Live preview for {saved.id}</p> : <Harness saveAndPreview onReviewInForm={review} onPersonaChange={(value)=>{changed(value);setSaved(value)}}/>}
    render(<Transition/>);
    const useAll=await screen.findByRole('button',{name:'Use all suggestions'});await waitFor(()=>expect(useAll).toHaveProperty('disabled',false))
    expect(screen.getByText('Review each suggestion',{selector:'summary'}).closest('details')?.open).toBe(false)
    await userEvent.click(screen.getByText('Review each suggestion',{selector:'summary'}))
    expect(screen.getByText('3',{selector:'.coach-suggestion-value'})).toBeTruthy()
    await userEvent.click(screen.getByRole('checkbox',{name:'Use this max sentences suggestion'}))
    await userEvent.click(screen.getByRole('button',{name:'Use selected suggestions'}))
    await screen.findByText('Live preview for 81')
    expect(apiMocks.resolveAdminPersonaSetupProposal).toHaveBeenCalledWith(81,51,71,'apply',expect.any(String),[1])
    expect(changed).toHaveBeenCalledWith(persona());expect(review).not.toHaveBeenCalled()
  })
  it('uses all suggestions by default when saving directly to preview',async()=>{
    apiMocks.createAdminPersonaSetupSession.mockResolvedValue(proposalSession())
    apiMocks.resolveAdminPersonaSetupProposal.mockResolvedValue({session:session(),persona:persona()})
    const changed=vi.fn();render(<Harness saveAndPreview onPersonaChange={changed}/>);
    const button=await screen.findByRole('button',{name:'Use all suggestions'});await waitFor(()=>expect(button).toHaveProperty('disabled',false));await userEvent.click(button)
    await waitFor(()=>expect(changed).toHaveBeenCalledWith(persona()))
    expect(apiMocks.resolveAdminPersonaSetupProposal.mock.calls[0][5]).toEqual([0])
  })
  it('keeps text typed while a transcript upload is reading',async()=>{
    let finish!:(value:{text:string})=>void
    apiMocks.readCoachVoiceTranscript.mockReturnValue(new Promise(resolve=>{finish=resolve}))
    render(<Harness/>);const composer=await screen.findByLabelText('Message Mia')
    await userEvent.upload(screen.getByLabelText(/Add a transcript/),new File(['One small step'],'talk.txt',{type:'text/plain'}))
    await screen.findByText('Reading your transcript…');await userEvent.type(composer,'Keep this new wording.')
    finish({text:'One small step'})
    await waitFor(()=>expect(composer).toHaveProperty('value','Keep this new wording.\n\nTranscript: talk.txt\nOne small step'))
  })
  it('shows an actionable server transcript error and retains the typed message',async()=>{
    apiMocks.readCoachVoiceTranscript.mockRejectedValue(new ApiRequestError('This transcript is long. Choose an excerpt of up to 22,000 characters.',{status:422}))
    render(<Harness/>);const composer=await screen.findByLabelText('Message Mia');await userEvent.type(composer,'Keep me.')
    await userEvent.upload(screen.getByLabelText(/Add a transcript/),new File(['long'],'talk.txt',{type:'text/plain'}))
    expect((await screen.findByRole('alert')).textContent).toContain('22,000 characters')
    expect(composer).toHaveProperty('value','Keep me.')
  })

})
