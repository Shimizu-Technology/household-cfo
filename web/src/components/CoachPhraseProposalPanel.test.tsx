// @vitest-environment jsdom

import { cleanup, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AdminContentSourceCandidate, AdminPersonaDetail, AdminPhraseProposal } from '../api'
import { CoachPhraseProposalPanel } from './CoachPhraseProposalPanel'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

const apiMocks = vi.hoisted(() => ({
  attestAdminPhraseProposal: vi.fn(),
  createAdminPhraseProposal: vi.fn(),
  fetchAdminContentSourcePhraseProposals: vi.fn(),
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

  it('lets an editor save and submit exact phrase settings without rendering private evidence', async () => {
    const draft = proposal({ status: 'draft', submitted_at: null, permissions: { edit: true, submit: true, review: false, promote: false } })
    const submitted = proposal()
    apiMocks.fetchAdminContentSourcePhraseProposals.mockResolvedValue({ phrase_proposals: [], permissions: { view: true, propose: true, review: false, promote: false } })
    apiMocks.createAdminPhraseProposal.mockResolvedValue(draft)
    apiMocks.submitAdminPhraseProposal.mockResolvedValue(submitted)
    renderPanel()

    expect(await screen.findByRole('heading', { name: /Review exact wording/i })).toBeTruthy()
    expect(screen.queryByText(candidate.evidence_excerpt)).toBeNull()
    await userEvent.type(screen.getByLabelText('Meaning and intent'), 'Choose one practical action.')
    await userEvent.click(screen.getByRole('button', { name: 'Save and submit for review' }))

    await waitFor(() => expect(apiMocks.createAdminPhraseProposal).toHaveBeenCalledTimes(1))
    expect(apiMocks.createAdminPhraseProposal).toHaveBeenCalledWith(7, expect.objectContaining({ candidate_id: 9, content_item_version_id: 22 }))
    await waitFor(() => expect(apiMocks.submitAdminPhraseProposal).toHaveBeenCalledWith(draft))
    expect(await screen.findByText(/reviewer must approve or reject/i)).toBeTruthy()
  })

  it('requires explicit attestation, then promotes only to the selected assistant', async () => {
    const submitted = proposal()
    const approved = proposal({
      attestation: { decision: 'approved', self_review: false, reviewed_at: '2026-10-02T01:00:00Z', reviewed_by: { id: 3, full_name: 'Coach Reviewer' } },
      permissions: { edit: false, submit: false, review: false, promote: true },
    })
    const persona = { id: 5, name: 'Coach Lani', draft_revision: 9 } as AdminPersonaDetail
    apiMocks.fetchAdminContentSourcePhraseProposals.mockResolvedValue({ phrase_proposals: [submitted], permissions: { view: true, propose: false, review: true, promote: false } })
    apiMocks.attestAdminPhraseProposal.mockResolvedValue(approved)
    apiMocks.promoteAdminPhraseProposal.mockResolvedValue({ persona: { ...persona, draft_revision: 10 }, phrase_promotion: { id: 8 } })
    apiMocks.fetchAdminPhraseProposal.mockResolvedValue({ ...approved, promotion_count: 1 })
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
  })
})
