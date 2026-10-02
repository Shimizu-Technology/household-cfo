// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AdminContentSource, CurrentUser } from '../api'
import { AuthContext } from '../contexts/authContextValue'
import { CoachContentSources } from './CoachContentSources'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

const apiMocks = vi.hoisted(() => ({
  fetchAdminContentSources: vi.fn(),
  fetchAdminContentSource: vi.fn(),
  fetchAdminContentSourceUrl: vi.fn(),
  updateAdminContentSourceCandidate: vi.fn(),
  acceptAdminContentSourceCandidate: vi.fn(),
  rejectAdminContentSourceCandidate: vi.fn(),
  reprocessAdminContentSource: vi.fn(),
  deleteAdminContentSource: vi.fn(),
  retryAdminContentSourceCleanups: vi.fn(),
  uploadAdminContentSource: vi.fn(),
}))

vi.mock('../api', async (importOriginal) => ({
  ...await importOriginal<typeof import('../api')>(),
  ...apiMocks,
}))

const currentUser = { id: 2, is_admin: false, is_coach: true } as CurrentUser
const mutationLifecycle: CoachWorkspaceMutationLifecycle = {
  pending: false,
  begin: () => ({ id: 1, workspaceId: 1 }),
  isCurrent: () => true,
  finish: () => undefined,
}

function source(
  permissions: AdminContentSource['permissions'],
  overrides: Partial<Pick<AdminContentSource, 'scope'>> & { candidateKind?: AdminContentSource['candidates'][number]['kind'] } = {},
): AdminContentSource {
  return {
    id: 7,
    scope: overrides.scope ?? 'coach',
    filename: 'coach-source.txt',
    content_type: 'text/plain',
    byte_size: 42,
    checksum_sha256: 'digest',
    status: 'needs_review',
    generation: 1,
    source_available: true,
    error: null,
    error_code: null,
    source_delete_error_code: null,
    processing_metadata: {},
    processed_at: '2026-10-01T00:00:00Z',
    source_deleted_at: null,
    created_at: '2026-10-01T00:00:00Z',
    updated_at: '2026-10-01T00:00:00Z',
    current_attempt: null,
    permissions,
    candidates: [{
      id: 9,
      source_id: 7,
      position: 0,
      status: 'proposed',
      title: 'One practical step',
      kind: overrides.candidateKind ?? 'guidance',
      content: 'Choose one practical next step.',
      topics: ['planning'],
      evidence_locator: { segment: 1 },
      evidence_excerpt: 'Choose one practical next step.',
      revision: 1,
      digest: 'candidate-digest',
      safety_code: null,
      accepted_content_item_id: null,
      accepted_content_item_version_id: null,
      accepted_content_item_version_kind: null,
      accepted_content_item_version_content: null,
      reviewed_at: null,
      updated_at: '2026-10-01T00:00:00Z',
    }],
  }
}

function renderSources(user: CurrentUser = currentUser) {
  return render(
    <AuthContext.Provider value={{
      isClerkEnabled: false,
      isSignedIn: true,
      isLoading: false,
      isVerifyingApi: false,
      currentUser: user,
      activeCoachWorkspaceId: 1,
      authError: null,
      refreshCurrentUser: async () => undefined,
      selectCoachWorkspace: () => undefined,
    }}>
      <CoachContentSources currentUser={user} selectedPersona={null} refreshRequest={0} mutationLifecycle={mutationLifecycle} onDirtyChange={() => undefined} onItemAccepted={() => undefined} onReviewItem={() => undefined} onPersonaChange={() => undefined} />
    </AuthContext.Provider>,
  )
}

describe('CoachContentSources role controls', () => {
  beforeEach(() => vi.clearAllMocks())
  afterEach(cleanup)

  it('gives an editor candidate fields and source maintenance without review decisions', async () => {
    const editorSource = source({ edit_candidates: true, review_candidates: false, download: true, reprocess: true, delete: true })
    apiMocks.fetchAdminContentSources.mockResolvedValue({
      sources: [editorSource],
      permissions: { upload_coach: true, upload_platform: false, retry_cleanup: false },
    })
    apiMocks.fetchAdminContentSource.mockResolvedValue(editorSource)
    renderSources()

    await userEvent.click(await screen.findByRole('button', { name: /coach-source\.txt/i }))
    const title = await screen.findByLabelText('Candidate title') as HTMLInputElement

    expect(title.disabled).toBe(false)
    expect(screen.getByRole('button', { name: 'Download source' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Delete source' })).toBeTruthy()
    expect(screen.queryByRole('button', { name: 'Create content draft' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Reject' })).toBeNull()
  })

  it('gives a reviewer read-only candidate wording and review decisions without upload or source mutation', async () => {
    const reviewerSource = source({ edit_candidates: false, review_candidates: true, download: true, reprocess: false, delete: false })
    apiMocks.fetchAdminContentSources.mockResolvedValue({
      sources: [reviewerSource],
      permissions: { upload_coach: false, upload_platform: false, retry_cleanup: false },
    })
    apiMocks.fetchAdminContentSource.mockResolvedValue(reviewerSource)
    renderSources()

    await userEvent.click(await screen.findByRole('button', { name: /coach-source\.txt/i }))
    const title = await screen.findByLabelText('Candidate title') as HTMLInputElement

    await waitFor(() => expect(title.disabled).toBe(true))
    expect(screen.queryByLabelText('Private source file')).toBeNull()
    expect(screen.getByRole('button', { name: 'Download source' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Create content draft' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Reject' })).toBeTruthy()
    expect(screen.queryByRole('button', { name: 'Delete source' })).toBeNull()
  })

  it('realigns upload ownership to the first permitted scope after permissions load', async () => {
    apiMocks.fetchAdminContentSources.mockResolvedValue({
      sources: [],
      permissions: { upload_coach: false, upload_platform: true, retry_cleanup: false },
    })
    renderSources({ id: 1, is_admin: true, is_coach: false } as CurrentUser)

    const owner = await screen.findByLabelText('Owner') as HTMLSelectElement
    await waitFor(() => expect(owner.value).toBe('platform'))
    expect(owner.querySelector('option[value="coach"]')).toBeNull()
  })

  it('requires a legacy platform phrase candidate to move to a supported type', async () => {
    const platformSource = source(
      { edit_candidates: true, review_candidates: true, download: true, reprocess: true, delete: true },
      { scope: 'platform', candidateKind: 'phrase' },
    )
    apiMocks.fetchAdminContentSources.mockResolvedValue({
      sources: [platformSource],
      permissions: { upload_coach: true, upload_platform: true, retry_cleanup: false },
    })
    apiMocks.fetchAdminContentSource.mockResolvedValue(platformSource)
    renderSources({ id: 1, is_admin: true, is_coach: false } as CurrentUser)

    await userEvent.click(await screen.findByRole('button', { name: /coach-source\.txt/i }))
    const kind = await screen.findByLabelText('Type') as HTMLSelectElement

    expect(kind.value).toBe('phrase')
    expect((kind.querySelector('option[value="phrase"]') as HTMLOptionElement | null)?.disabled).toBe(true)
    expect(screen.getByText(/Approved phrases belong to a coaching workspace/)).toBeTruthy()
    expect((screen.getByRole('button', { name: 'Save edits' }) as HTMLButtonElement).disabled).toBe(true)
    expect((screen.getByRole('button', { name: 'Create content draft' }) as HTMLButtonElement).disabled).toBe(true)

    apiMocks.rejectAdminContentSourceCandidate.mockResolvedValue({
      ...platformSource.candidates[0],
      status: 'rejected',
    })
    await userEvent.click(screen.getByRole('button', { name: 'Reject' }))
    await userEvent.click(screen.getByRole('button', { name: 'Yes, reject' }))
    await waitFor(() => expect(apiMocks.rejectAdminContentSourceCandidate).toHaveBeenCalledWith(7, platformSource.candidates[0]))
  })
})
