// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError, type AdminPersonaDetail, type AdminPersonaSetupSession, type PersonaConfiguration } from '../api'
import { PersonaSetupChat } from './PersonaSetupChat'
import { useCoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

const apiMocks = vi.hoisted(() => ({
  createAdminPersonaSetupSession: vi.fn(),
  createAdminPersonaSetupTurn: vi.fn(),
  rebaseAdminPersonaSetupSession: vi.fn(),
  abandonAdminPersonaSetupSession: vi.fn(),
  resolveAdminPersonaSetupProposal: vi.fn(),
}))

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
  personaId = 81,
  manualDirty = false,
  onPersonaChange = vi.fn(),
  onReviewInForm = vi.fn(),
}: {
  workspaceId?: number
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
    vi.clearAllMocks()
    apiMocks.createAdminPersonaSetupSession.mockResolvedValue(session())
  })
  afterEach(cleanup)

  it('keeps setup private and applies only a reviewed proposal', async () => {
    const onPersonaChange = vi.fn()
    apiMocks.createAdminPersonaSetupTurn.mockResolvedValue(proposalSession())
    apiMocks.resolveAdminPersonaSetupProposal.mockResolvedValue({ session: session(), persona: persona() })
    render(<Harness onPersonaChange={onPersonaChange} />)

    expect(await screen.findByText(/Participant household and financial data are excluded/)).toBeTruthy()
    await userEvent.type(screen.getByLabelText('Message Mia'), 'Her name is Mrs. Mel.')
    await userEvent.click(screen.getByRole('button', { name: 'Send to Mia' }))

    expect(await screen.findByText('Human coach name')).toBeTruthy()
    expect(screen.getByText('Coach said')).toBeTruthy()
    expect(screen.getByText('Mrs. Mel')).toBeTruthy()
    expect(onPersonaChange).not.toHaveBeenCalled()

    await userEvent.click(screen.getByRole('button', { name: 'Apply to saved draft' }))
    await vi.waitFor(() => expect(onPersonaChange).toHaveBeenCalledTimes(1))
    expect(apiMocks.resolveAdminPersonaSetupProposal.mock.calls[0][3]).toBe('apply')
  })

  it('blocks apply for manual edits and can copy the proposal into the form', async () => {
    const onReviewInForm = vi.fn()
    apiMocks.createAdminPersonaSetupSession.mockResolvedValue(proposalSession())
    render(<Harness manualDirty onReviewInForm={onReviewInForm} />)

    expect((await screen.findByRole('button', { name: 'Apply to saved draft' }) as HTMLButtonElement).disabled).toBe(true)
    await userEvent.click(screen.getByRole('button', { name: 'Review in form' }))
    expect(onReviewInForm).toHaveBeenCalledWith(authoringState, 'identity.human_coach_name')
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
      .mockRejectedValueOnce(new ApiRequestError('Nothing changed. Try again.', {
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
    expect(screen.getByRole('alert').textContent).toContain('Nothing changed. Try again.')

    await userEvent.click(screen.getByRole('button', { name: 'Send to Mia' }))
    await screen.findByText('Human coach name')
    expect(apiMocks.createAdminPersonaSetupTurn.mock.calls[1][3]).not.toBe(apiMocks.createAdminPersonaSetupTurn.mock.calls[0][3])
  })

  it('reuses a proposal action key after a lost response', async () => {
    apiMocks.createAdminPersonaSetupSession.mockResolvedValue(proposalSession())
    apiMocks.resolveAdminPersonaSetupProposal
      .mockRejectedValueOnce(new Error('The response was lost.'))
      .mockResolvedValueOnce({ session: session(), persona: persona() })
    render(<Harness />)

    await userEvent.click(await screen.findByRole('button', { name: 'Apply to saved draft' }))
    expect((await screen.findByRole('alert')).textContent).toContain('The response was lost.')
    await userEvent.click(screen.getByRole('button', { name: 'Apply to saved draft' }))
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

    await userEvent.click(await screen.findByRole('button', { name: 'Apply to saved draft' }))
    expect((await screen.findByRole('alert')).textContent).toContain('The apply response was lost.')
    await userEvent.click(screen.getByRole('button', { name: 'Reject proposal' }))
    expect((await screen.findByRole('alert')).textContent).toContain('The reject response was lost.')
    await userEvent.click(screen.getByRole('button', { name: 'Apply to saved draft' }))
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
})
