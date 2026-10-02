// @vitest-environment jsdom

import { cleanup, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError } from '../api'
import type { AdminContentSourceCandidate, AdminPersonaDetail, AdminPhraseProposal } from '../api'
import { CoachPhraseProposalPanel } from './CoachPhraseProposalPanel'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

const apiMocks = vi.hoisted(() => ({
  attestAdminPhraseProposal: vi.fn(),
  createAdminPhraseProposal: vi.fn(),
  fetchAdminContentSourcePhraseProposals: vi.fn(),
  fetchAdminPersona: vi.fn(),
  fetchAdminPhraseProposal: vi.fn(),
  promoteAdminPhraseProposal: vi.fn(),
  submitAdminPhraseProposal: vi.fn(),
  updateAdminPhraseProposal: vi.fn(),
}))

vi.mock('../api', async (importOriginal) => ({
  ...await importOriginal<typeof import('../api')>(),
  ...apiMocks,
}))

const lifecycle: CoachWorkspaceMutationLifecycle = {
  pending: false,
  begin: () => ({ id: 1, workspaceId: 1 }),
  isCurrent: () => true,
  finish: () => undefined,
}

const candidate: AdminContentSourceCandidate = {
  id: 9,
  source_id: 7,
  position: 0,
  status: 'accepted',
  title: 'One step phrase',
  kind: 'phrase',
  content: 'One step at a time',
  topics: [],
  evidence_locator: { segment: 1 },
  evidence_excerpt: 'private evidence must stay outside this panel',
  revision: 2,
  digest: 'candidate-digest',
  safety_code: null,
  accepted_content_item_id: 20,
  accepted_content_item_version_id: 22,
  accepted_content_item_version_kind: 'phrase',
  accepted_content_item_version_content: 'One step at a time',
  reviewed_at: '2026-10-02T00:00:00Z',
  updated_at: '2026-10-02T00:00:00Z',
}

const phrase = {
  text: 'One step at a time',
  meaning: 'Choose one practical action.',
  allowed_contexts: ['general'] as const,
  prohibited_contexts: ['crisis'] as const,
  frequency: 'rare' as const,
  caution: 'Avoid during urgent safety needs.',
}

function proposal(overrides: Partial<AdminPhraseProposal> = {}): AdminPhraseProposal {
  return {
    id: 31,
    source_id: 7,
    source_label: 'coach-source.txt',
    content_item_version_id: 22,
    status: 'submitted',
    phrase: { ...phrase, allowed_contexts: [...phrase.allowed_contexts], prohibited_contexts: [...phrase.prohibited_contexts] },
    revision: 4,
    digest: 'proposal-digest',
    submitted_at: '2026-10-02T00:00:00Z',
    superseded_at: null,
    proposed_by: { id: 2, full_name: 'Coach Editor' },
    attestation: null,
    promotion_count: 0,
    permissions: { edit: false, submit: false, review: true, promote: false },
    ...overrides,
  }
}

function renderPanel(props: Partial<Parameters<typeof CoachPhraseProposalPanel>[0]> = {}) {
  return render(<CoachPhraseProposalPanel
    sourceId={7}
    candidate={candidate}
    selectedPersona={null}
    mutationLifecycle={lifecycle}
    disabled={false}
    onDirtyChange={() => undefined}
    onBusyChange={() => undefined}
    onPersonaChange={() => undefined}
    {...props}
  />)
}

describe('CoachPhraseProposalPanel', () => {
  beforeEach(() => vi.clearAllMocks())
  afterEach(cleanup)

  it('shows the accepted phrase waiting stage before its content version is approved', () => {
    renderPanel({
      candidate: {
        ...candidate,
        accepted_content_item_version_id: null,
        accepted_content_item_version_kind: null,
        accepted_content_item_version_content: null,
      },
    })

    expect(screen.getByRole('heading', { name: 'Approve the content draft first' })).toBeTruthy()
    expect(screen.getByText(/Approve its exact version below/i)).toBeTruthy()
    expect(apiMocks.fetchAdminContentSourcePhraseProposals).not.toHaveBeenCalled()
  })

  it('lets an editor save and submit exact phrase settings without rendering private evidence', async () => {
    const exactText = '  One  step\nat a time  '
    const exactCandidate = { ...candidate, kind: 'guidance' as const, content: 'stale candidate wording', accepted_content_item_version_content: exactText }
    const exactPhrase = { ...phrase, text: exactText, allowed_contexts: [...phrase.allowed_contexts], prohibited_contexts: [...phrase.prohibited_contexts] }
    const draft = proposal({ status: 'draft', phrase: exactPhrase, submitted_at: null, permissions: { edit: true, submit: true, review: false, promote: false } })
    const submitted = proposal({ phrase: exactPhrase })
    apiMocks.fetchAdminContentSourcePhraseProposals.mockResolvedValue({ phrase_proposals: [], permissions: { view: true, propose: true, review: false, promote: false } })
    apiMocks.createAdminPhraseProposal.mockResolvedValue(draft)
    apiMocks.submitAdminPhraseProposal.mockResolvedValue(submitted)
    renderPanel({ candidate: exactCandidate })

    expect(await screen.findByRole('heading', { name: /Review exact wording/i })).toBeTruthy()
    expect(screen.queryByText(candidate.evidence_excerpt)).toBeNull()
    await userEvent.type(screen.getByLabelText('Meaning and intent'), 'Choose one practical action.')
    await userEvent.click(screen.getByRole('button', { name: 'Save and submit for review' }))

    await waitFor(() => expect(apiMocks.createAdminPhraseProposal).toHaveBeenCalledTimes(1))
    expect(apiMocks.createAdminPhraseProposal).toHaveBeenCalledWith(7, expect.objectContaining({
      candidate_id: 9, content_item_version_id: 22, phrase: expect.objectContaining({ text: exactText }),
    }))
    await waitFor(() => expect(apiMocks.submitAdminPhraseProposal).toHaveBeenCalledWith(draft))
    expect(await screen.findByText(/reviewer must approve or reject/i)).toBeTruthy()
  })

  it('requires explicit attestation, then promotes only to the selected assistant', async () => {
    const submitted = proposal()
    const approved = proposal({
      attestation: { decision: 'approved', self_review: false, reviewed_at: '2026-10-02T01:00:00Z', reviewed_by: { id: 3, full_name: 'Coach Reviewer' } },
      permissions: { edit: false, submit: false, review: false, promote: true },
    })
    const persona = { id: 5, name: 'Coach Lani', status: 'draft', permissions: { publish: true }, draft_revision: 9 } as AdminPersonaDetail
    apiMocks.fetchAdminContentSourcePhraseProposals.mockResolvedValue({ phrase_proposals: [submitted], permissions: { view: true, propose: false, review: true, promote: false } })
    apiMocks.attestAdminPhraseProposal.mockResolvedValue(approved)
    apiMocks.promoteAdminPhraseProposal.mockResolvedValue({ persona: { ...persona, draft_revision: 10 }, phrase_promotion: { id: 8 } })
    apiMocks.fetchAdminPhraseProposal.mockRejectedValue(new Error('refresh unavailable'))
    const onPersonaChange = vi.fn()
    renderPanel({ selectedPersona: persona, onPersonaChange })

    expect((await screen.findByDisplayValue('One step at a time') as HTMLInputElement).disabled).toBe(true)
    await userEvent.click(screen.getByRole('button', { name: 'Approve exact phrase' }))
    const confirmation = screen.getByRole('alert')
    expect(within(confirmation).getByText(/Approve this exact wording/i)).toBeTruthy()
    await userEvent.click(within(confirmation).getByRole('button', { name: 'Yes, approve' }))

    await waitFor(() => expect(apiMocks.attestAdminPhraseProposal).toHaveBeenCalledWith(submitted, 'approved'))
    await userEvent.click(await screen.findByRole('button', { name: 'Promote to selected assistant' }))
    await waitFor(() => expect(apiMocks.promoteAdminPhraseProposal).toHaveBeenCalledWith(5, 31, 9))
    expect(onPersonaChange).toHaveBeenCalledWith(expect.objectContaining({ id: 5, draft_revision: 10 }))
    expect(await screen.findByText(/Phrase added to Coach Lani\. Its review count could not refresh/i)).toBeTruthy()
    expect(screen.queryByText(/could not be added/i)).toBeNull()
  })

  it('labels the sole-owner self-review exception before promotion', async () => {
    const approved = proposal({
      attestation: { decision: 'approved', self_review: true, reviewed_at: '2026-10-02T01:00:00Z', reviewed_by: { id: 2, full_name: 'Workspace Owner' } },
      permissions: { edit: false, submit: false, review: false, promote: true },
    })
    apiMocks.fetchAdminContentSourcePhraseProposals.mockResolvedValue({
      phrase_proposals: [approved],
      permissions: { view: true, propose: false, review: true, promote: true },
    })
    renderPanel({ selectedPersona: { id: 5, name: 'Coach Lani', status: 'draft', permissions: { publish: true }, draft_revision: 9 } as AdminPersonaDetail })

    expect(await screen.findByText('Owner self-review approved')).toBeTruthy()
    expect(screen.getByText(/explicit sole-owner self-review/i)).toBeTruthy()
  })

  it('retries an uncertain create without changing exact text', async () => {
    const exactText = 'Keep  both spaces\nand this line'
    const exactCandidate = { ...candidate, accepted_content_item_version_content: exactText }
    const saved = proposal({ status: 'draft', phrase: { ...phrase, text: exactText, allowed_contexts: ['general'], prohibited_contexts: ['crisis'] }, submitted_at: null, permissions: { edit: true, submit: true, review: false, promote: false } })
    apiMocks.fetchAdminContentSourcePhraseProposals.mockResolvedValue({ phrase_proposals: [], permissions: { view: true, propose: true, review: false, promote: false } })
    apiMocks.createAdminPhraseProposal.mockRejectedValueOnce(new Error('Connection ended before the response.')).mockResolvedValueOnce(saved)
    renderPanel({ candidate: exactCandidate })

    await userEvent.type(await screen.findByLabelText('Meaning and intent'), 'Choose one practical action.')
    await userEvent.click(screen.getByRole('button', { name: 'Save private draft' }))
    expect((await screen.findByRole('alert')).textContent).toContain('Connection ended before the response.')
    expect(screen.queryByRole('button', { name: 'Retry phrase review' })).toBeNull()
    expect((screen.getByLabelText('Meaning and intent') as HTMLTextAreaElement).value).toBe('Choose one practical action.')
    await userEvent.click(screen.getByRole('button', { name: 'Save private draft' }))

    await waitFor(() => expect(apiMocks.createAdminPhraseProposal).toHaveBeenCalledTimes(2))
    expect(apiMocks.createAdminPhraseProposal.mock.calls[1][1].phrase.text).toBe(exactText)
    expect(await screen.findByText(/saved as a private draft/i)).toBeTruthy()
  })

  it('preserves unsaved phrase edits when the source candidate object refreshes', async () => {
    apiMocks.fetchAdminContentSourcePhraseProposals.mockResolvedValue({
      phrase_proposals: [],
      permissions: { view: true, propose: true, review: false, promote: false },
    })
    const view = renderPanel()

    const meaning = await screen.findByLabelText('Meaning and intent') as HTMLTextAreaElement
    await userEvent.type(meaning, 'Keep this unsaved meaning.')
    view.rerender(<CoachPhraseProposalPanel
      sourceId={7}
      candidate={{ ...candidate, updated_at: '2026-10-02T01:00:00Z' }}
      selectedPersona={null}
      mutationLifecycle={lifecycle}
      disabled={false}
      onDirtyChange={() => undefined}
      onBusyChange={() => undefined}
      onPersonaChange={() => undefined}
    />)

    expect((screen.getByLabelText('Meaning and intent') as HTMLTextAreaElement).value).toBe('Keep this unsaved meaning.')
    expect(apiMocks.fetchAdminContentSourcePhraseProposals).toHaveBeenCalledTimes(1)
  })

  it('can retry the initial phrase review load', async () => {
    apiMocks.fetchAdminContentSourcePhraseProposals
      .mockRejectedValueOnce(new Error('Phrase review could not load.'))
      .mockResolvedValueOnce({ phrase_proposals: [], permissions: { view: true, propose: true, review: false, promote: false } })
    renderPanel()

    expect((await screen.findByRole('alert')).textContent).toContain('Phrase review could not load.')
    await userEvent.click(screen.getByRole('button', { name: 'Retry phrase review' }))

    await waitFor(() => expect(apiMocks.fetchAdminContentSourcePhraseProposals).toHaveBeenCalledTimes(2))
    expect(await screen.findByRole('heading', { name: /Review exact wording/i })).toBeTruthy()
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('reloads an ordinary conflicting assistant and gives a clear retry path', async () => {
    const approved = proposal({
      attestation: { decision: 'approved', self_review: false, reviewed_at: '2026-10-02T01:00:00Z', reviewed_by: { id: 3, full_name: 'Coach Reviewer' } },
      permissions: { edit: false, submit: false, review: false, promote: true },
    })
    const persona = { id: 5, name: 'Coach Lani', status: 'draft', permissions: { publish: true }, draft_revision: 9 } as AdminPersonaDetail
    const latest = { ...persona, draft_revision: 10 } as AdminPersonaDetail
    apiMocks.fetchAdminContentSourcePhraseProposals.mockResolvedValue({ phrase_proposals: [approved], permissions: { view: true, propose: false, review: true, promote: true } })
    apiMocks.promoteAdminPhraseProposal.mockRejectedValue(new ApiRequestError('Assistant changed.', { status: 409, code: 'persona_draft_conflict' }))
    apiMocks.fetchAdminPersona.mockResolvedValue(latest)
    const onPersonaChange = vi.fn()
    renderPanel({ selectedPersona: persona, onPersonaChange })

    await userEvent.click(await screen.findByRole('button', { name: 'Promote to selected assistant' }))
    expect(await screen.findByText(/latest draft is loaded; review it and retry/i)).toBeTruthy()
    expect(onPersonaChange).toHaveBeenCalledWith(latest)
  })

  it('explains why archived and read-only assistants cannot receive a promotion', async () => {
    const approved = proposal({
      attestation: { decision: 'approved', self_review: false, reviewed_at: '2026-10-02T01:00:00Z', reviewed_by: { id: 3, full_name: 'Coach Reviewer' } },
      permissions: { edit: false, submit: false, review: false, promote: true },
    })
    apiMocks.fetchAdminContentSourcePhraseProposals.mockResolvedValue({ phrase_proposals: [approved], permissions: { view: true, propose: false, review: true, promote: true } })
    const archived = { id: 5, name: 'Archived Mia', status: 'archived', permissions: { publish: true }, draft_revision: 9 } as AdminPersonaDetail
    const view = renderPanel({ selectedPersona: archived })

    expect(await screen.findByText(/Restore the assistant before adding reviewed phrases/i)).toBeTruthy()
    expect((screen.getByRole('button', { name: 'Promote to selected assistant' }) as HTMLButtonElement).disabled).toBe(true)
    view.rerender(<CoachPhraseProposalPanel sourceId={7} candidate={candidate} selectedPersona={{ ...archived, name: 'Read-only Mia', status: 'draft', permissions: { publish: false } } as AdminPersonaDetail} mutationLifecycle={lifecycle} disabled={false} onDirtyChange={() => undefined} onBusyChange={() => undefined} onPersonaChange={() => undefined} />)
    expect(await screen.findByText(/read-only for your role/i)).toBeTruthy()
  })
})
