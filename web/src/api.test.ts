import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  ApiRequestError,
  archiveAdminPersona,
  approveAdminContentItem,
  createAdminContentItem,
  createAdminContentPack,
  createAdminPersona,
  createBudgetCategory,
  createIncomeScheduleEntry,
  createIncomeSource,
  acceptAdminContentSourceCandidate,
  deleteAdminContentSource,
  deleteAdminCohortPersonaAssignment,
  fetchAppData,
  fetchAdminCohortPersonaAssignment,
  fetchAdminPersona,
  fetchAdminPersonaAssignableCohorts,
  fetchAdminPersonas,
  fetchAdminPersonaVersion,
  fetchAdminContentItems,
  fetchAdminContentPacks,
  fetchAdminContentSource,
  fetchAdminContentSources,
  previewAdminPersona,
  publishAdminPersona,
  publishAdminContentPack,
  restoreAdminPersona,
  rejectAdminContentSourceCandidate,
  reprocessAdminContentSource,
  retryAdminContentSourceCleanups,
  rollbackAdminPersonaVersion,
  sendMiaMessage,
  setActiveCoachWorkspaceId,
  setAuthTokenGetter,
  updateAdminCohortPersonaAssignment,
  updateAdminPersona,
  updateAdminContentItem,
  updateAdminContentPack,
  updateAdminContentSourceCandidate,
  updateAdminPersonaContentPacks,
  uploadDocumentImport,
  uploadAdminContentSource,
  updateBudgetAllocation,
  updateIncomeScheduleEntry,
  updateIncomeSource,
  archiveIncomeSource,
  bulkConfirmTransactionDrafts,
  confirmTransactionDraft,
  restoreIncomeSource,
  deleteIncomeScheduleEntry,
  matchTransactionDraft,
  reopenTransactionDraft,
  saveWorkspaceSetup,
  updateTransactionDraft,
} from './api'

const completedPayload = {
  user_message: { id: 1, role: 'user', author: 'You', content: 'Hello', attachments: [], created_at: null },
  assistant_message: { id: 2, role: 'assistant', author: 'Mia', content: 'Verified reply', attachments: [], created_at: null },
}

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
  setActiveCoachWorkspaceId(null)
  setAuthTokenGetter(null)
})

describe('coach workspace request boundary', () => {
  it('sends the selected workspace on reads and writes', async () => {
    const fetchMock = vi.fn().mockImplementation(async (_url, options?: RequestInit) => (
      options?.method === 'POST'
        ? jsonResponse({ persona: { id: 7 } }, 201)
        : jsonResponse({ personas: [] })
    ))
    vi.stubGlobal('fetch', fetchMock)
    setActiveCoachWorkspaceId(42)

    await fetchAdminPersonas()
    await createAdminPersona({ name: 'Workspace assistant', description: '' })

    for (const call of fetchMock.mock.calls) {
      expect((call[1] as RequestInit).headers).toMatchObject({ 'X-Coach-Workspace-Id': '42' })
    }
  })
})

function jsonResponse(payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

describe('budget operation idempotency contract', () => {
  it('sends the caller-owned stable key on category and allocation writes', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ budget: { total_monthly_outflow: 250 } }, 201))
      .mockResolvedValueOnce(jsonResponse({ budget: { total_monthly_outflow: 325 } }))
    vi.stubGlobal('fetch', fetchMock)

    await createBudgetCategory({ name: 'Dining', stack_key: 'discretionary', monthly_amount: 250 }, 2026, 'category-attempt')
    await updateBudgetAllocation(44, 325, 'allocation-attempt')

    expect((fetchMock.mock.calls[0][1] as RequestInit).headers).toMatchObject({ 'Idempotency-Key': 'category-attempt' })
    expect((fetchMock.mock.calls[1][1] as RequestInit).headers).toMatchObject({ 'Idempotency-Key': 'allocation-attempt' })
  })
})

describe('manual setup idempotency contract', () => {
  it('sends the caller-owned stable key for the typed setup transaction', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ workspace: {} }))
    vi.stubGlobal('fetch', fetchMock)

    await saveWorkspaceSetup({ household_name: 'Typed Household' }, 'workspace-setup-attempt')

    const request = fetchMock.mock.calls[0][1] as RequestInit
    expect((request.headers as Record<string, string>)['Idempotency-Key']).toBe('workspace-setup-attempt')
  })
})

describe('income operation idempotency contract', () => {
  it('sends stable keys for source and schedule writes', async () => {
    const fetchMock = vi.fn()
      .mockImplementation(async () => jsonResponse({ income_source: {}, income_schedule_entry: {}, budget: { monthly_income: 5000 } }, 200))
    vi.stubGlobal('fetch', fetchMock)

    const source = { label: 'Primary salary', source_type: 'job', amount: '5000', cadence: 'monthly', starts_on: '2026-10-01' }
    const schedule = { income_source_id: 7, entry_type: 'recurring_change' as const, amount: '5500', cadence: 'monthly', effective_on: '2027-01-01' }
    await createIncomeSource(source, 2026, 'source-create')
    await updateIncomeSource(7, source, 2026, 'source-update')
    await archiveIncomeSource(7, '2026-12-01', 2026, 'source-archive')
    await restoreIncomeSource(7, 2026, 'source-restore')
    await createIncomeScheduleEntry(schedule, 2026, 'schedule-create')
    await updateIncomeScheduleEntry(9, schedule, 2026, 'schedule-update')
    await deleteIncomeScheduleEntry(9, 2026, 'schedule-delete')

    expect(fetchMock.mock.calls.map((call) => ((call[1] as RequestInit).headers as Record<string, string>)['Idempotency-Key'])).toEqual([
      'source-create', 'source-update', 'source-archive', 'source-restore', 'schedule-create', 'schedule-update', 'schedule-delete',
    ])
    expect(fetchMock.mock.calls.map((call) => String(call[0]).replace(/^.*\/api/, '/api'))).toEqual([
      '/api/v1/income_sources?year=2026',
      '/api/v1/income_sources/7?year=2026',
      '/api/v1/income_sources/7?year=2026',
      '/api/v1/income_sources/7/restore?year=2026',
      '/api/v1/income_schedule_entries?year=2026',
      '/api/v1/income_schedule_entries/9?year=2026',
      '/api/v1/income_schedule_entries/9?year=2026',
    ])
  })
})

describe('transaction resolution idempotency contract', () => {
  it('sends caller-owned stable keys for confirm, bulk confirm, match, and reopen', async () => {
    const fetchMock = vi.fn()
      .mockImplementation(async () => jsonResponse({ workspace: {} }))
    vi.stubGlobal('fetch', fetchMock)

    await confirmTransactionDraft(11, { amount: '24.50' }, 'transaction-confirm-attempt')
    await bulkConfirmTransactionDrafts([13, 12], 2026, 'CONFIRM 2', 'transaction-bulk-confirm-attempt')
    await matchTransactionDraft(14, 91, 'transaction-match-attempt')
    await reopenTransactionDraft(15, 'transaction-reopen-attempt')

    expect(fetchMock.mock.calls.map((call) => ((call[1] as RequestInit).headers as Record<string, string>)['Idempotency-Key'])).toEqual([
      'transaction-confirm-attempt',
      'transaction-bulk-confirm-attempt',
      'transaction-match-attempt',
      'transaction-reopen-attempt',
    ])
    expect(fetchMock.mock.calls.map((call) => String(call[0]).replace(/^.*\/api/, '/api'))).toEqual([
      '/api/v1/transaction_drafts/11/confirm',
      '/api/v1/transaction_drafts/bulk_confirm',
      '/api/v1/transaction_drafts/14/match',
      '/api/v1/transaction_drafts/15/reopen',
    ])
  })

  it('sends an explicit retained removed and new split contract for manual edits', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ transaction_draft: {}, workspace: {} }))
    vi.stubGlobal('fetch', fetchMock)

    await updateTransactionDraft(11, {
      amount: '50',
      removed_split_ids: [102],
      splits: [
        { id: 101, amount: '30', budget_category_id: 4 },
        { amount: '20', budget_category_id: 5 },
      ],
    }, 'transaction-split-edit')

    const request = fetchMock.mock.calls[0][1] as RequestInit
    expect((request.headers as Record<string, string>)['Idempotency-Key']).toBe('transaction-split-edit')
    expect(JSON.parse(String(request.body))).toEqual({
      transaction_draft: {
        amount: '50',
        removed_split_ids: [102],
        splits: [
          { id: 101, amount: '30', budget_category_id: 4 },
          { amount: '20', budget_category_id: 5 },
        ],
      },
    })
  })
})

describe('Persona Studio API contract', () => {
  it('uses explicit approval, publication, and exact persona source-link envelopes', async () => {
    const item = { id: 4, title: 'One clear question' }
    const pack = { id: 8, name: 'Coach method' }
    const persona = { id: 17, name: 'Coach Lani' }
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ items: [item] }))
      .mockResolvedValueOnce(jsonResponse({ item }, 201))
      .mockResolvedValueOnce(jsonResponse({ item }))
      .mockResolvedValueOnce(jsonResponse({ item, approved_version: { id: 12 } }))
      .mockResolvedValueOnce(jsonResponse({ packs: [pack] }))
      .mockResolvedValueOnce(jsonResponse({ pack }, 201))
      .mockResolvedValueOnce(jsonResponse({ pack }))
      .mockResolvedValueOnce(jsonResponse({ pack, published_version: { id: 21 } }))
      .mockResolvedValueOnce(jsonResponse({ persona }))
    vi.stubGlobal('fetch', fetchMock)

    expect(await fetchAdminContentItems()).toEqual([item])
    await createAdminContentItem({ title: 'One clear question', scope: 'coach', kind: 'guidance', draft_content: 'Ask one question.', always_on: false })
    await updateAdminContentItem(4, { title: 'One clear question', kind: 'guidance', draft_content: 'Ask one direct question.', always_on: false, draft_revision: 1 })
    await approveAdminContentItem(4, 2, 'item-draft-digest')
    expect(await fetchAdminContentPacks()).toEqual([pack])
    await createAdminContentPack({ name: 'Coach method', description: '', scope: 'coach', pack_kind: 'coaching_method', item_version_ids: [12] })
    await updateAdminContentPack(8, { name: 'Coach method', description: '', pack_kind: 'coaching_method', item_version_ids: [12], draft_revision: 2 })
    await publishAdminContentPack(8, { draft_revision: 2, draft_manifest_digest: 'pack-draft-digest', expected_published_version_id: null })
    await updateAdminPersonaContentPacks(17, 3, [21])

    expect(fetchMock.mock.calls.map((call) => String(call[0]).replace(/^.*\/api/, '/api'))).toEqual([
      '/api/v1/admin/content_items',
      '/api/v1/admin/content_items',
      '/api/v1/admin/content_items/4',
      '/api/v1/admin/content_items/4/approve',
      '/api/v1/admin/content_packs',
      '/api/v1/admin/content_packs',
      '/api/v1/admin/content_packs/8',
      '/api/v1/admin/content_packs/8/publish',
      '/api/v1/admin/personas/17/content_packs',
    ])
    expect(JSON.parse(String((fetchMock.mock.calls[8][1] as RequestInit).body))).toEqual({
      content_packs: { draft_revision: 3, pack_version_ids: [21] },
    })
    expect(JSON.parse(String((fetchMock.mock.calls[3][1] as RequestInit).body))).toEqual({
      item: { draft_revision: 2, draft_digest: 'item-draft-digest' },
    })
    expect(JSON.parse(String((fetchMock.mock.calls[7][1] as RequestInit).body))).toEqual({
      pack: { draft_revision: 2, draft_manifest_digest: 'pack-draft-digest', expected_published_version_id: null },
    })
  })

  it('uses the versioned draft lifecycle endpoints and request envelopes', async () => {
    const persona = { id: 17, name: 'Coach Lani' }
    const preview = { digest: 'preview-digest' }
    const version = { id: 31, number: 1 }
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ personas: [persona] }))
      .mockResolvedValueOnce(jsonResponse({ persona }))
      .mockResolvedValueOnce(jsonResponse({ persona }, 201))
      .mockResolvedValueOnce(jsonResponse({ persona }))
      .mockResolvedValueOnce(jsonResponse({ persona }))
      .mockResolvedValueOnce(jsonResponse({ persona }))
      .mockResolvedValueOnce(jsonResponse({ persona, preview }))
      .mockResolvedValueOnce(jsonResponse({ persona, published_version: version }))
      .mockResolvedValueOnce(jsonResponse({ persona, version }))
      .mockResolvedValueOnce(jsonResponse({ persona, published_version: version }))
    vi.stubGlobal('fetch', fetchMock)
    setAuthTokenGetter(async () => 'staff-token')

    expect(await fetchAdminPersonas()).toEqual([persona])
    expect(await fetchAdminPersona(17)).toEqual(persona)
    expect(await createAdminPersona({ name: 'Coach Lani' })).toEqual(persona)
    expect(await updateAdminPersona(17, { draft_revision: 2, description: 'Clear and kind.' })).toEqual(persona)
    expect(await archiveAdminPersona(17)).toEqual(persona)
    expect(await restoreAdminPersona(17)).toEqual(persona)
    expect(await previewAdminPersona(17, 2, 'Can I afford this?')).toEqual({ persona, preview })
    expect(await publishAdminPersona(17, {
      draft_revision: 2,
      preview_digest: 'preview-digest',
      expected_published_version_id: 30,
    })).toEqual({ persona, published_version: version })
    expect(await fetchAdminPersonaVersion(17, 31)).toEqual({ persona, version })
    expect(await rollbackAdminPersonaVersion(17, 31, {
      draft_revision: 2,
      expected_published_version_id: 32,
    })).toEqual({ persona, published_version: version })

    expect(fetchMock).toHaveBeenCalledTimes(10)
    expect(fetchMock.mock.calls.every((call) => (
      (call[1] as RequestInit).headers as Record<string, string>
    ).Authorization === 'Bearer staff-token')).toBe(true)
    expect(fetchMock.mock.calls.map((call) => String(call[0]).replace(/^.*\/api/, '/api'))).toEqual([
      '/api/v1/admin/personas',
      '/api/v1/admin/personas/17',
      '/api/v1/admin/personas',
      '/api/v1/admin/personas/17',
      '/api/v1/admin/personas/17',
      '/api/v1/admin/personas/17/restore',
      '/api/v1/admin/personas/17/preview',
      '/api/v1/admin/personas/17/publish',
      '/api/v1/admin/personas/17/versions/31',
      '/api/v1/admin/personas/17/versions/31/rollback',
    ])
    expect((fetchMock.mock.calls[3][1] as RequestInit).method).toBe('PATCH')
    expect(fetchMock.mock.calls[2][1]).not.toHaveProperty('signal')
    expect(JSON.parse(String((fetchMock.mock.calls[3][1] as RequestInit).body))).toEqual({
      persona: { draft_revision: 2, description: 'Clear and kind.' },
    })
    expect((fetchMock.mock.calls[4][1] as RequestInit).method).toBe('DELETE')
    expect(JSON.parse(String((fetchMock.mock.calls[6][1] as RequestInit).body))).toEqual({
      preview: { draft_revision: 2, sample_prompt: 'Can I afford this?' },
    })
    expect(JSON.parse(String((fetchMock.mock.calls[7][1] as RequestInit).body))).toEqual({
      publish: {
        draft_revision: 2,
        preview_digest: 'preview-digest',
        expected_published_version_id: 30,
      },
    })
    expect(JSON.parse(String((fetchMock.mock.calls[9][1] as RequestInit).body))).toEqual({
      rollback: { draft_revision: 2, expected_published_version_id: 32 },
    })
  })

  it('uses optimistic assignment values for replace and removal', async () => {
    const assignment = { id: 44, persona: { id: 17, name: 'Coach Lani' } }
    const cohort = { id: 9, persona_assignment: assignment }
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ cohorts: [cohort] }))
      .mockResolvedValueOnce(jsonResponse({ persona_assignment: assignment }))
      .mockResolvedValueOnce(jsonResponse({ persona_assignment: assignment }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
    vi.stubGlobal('fetch', fetchMock)

    expect(await fetchAdminPersonaAssignableCohorts()).toEqual([cohort])
    expect(await fetchAdminCohortPersonaAssignment(9)).toEqual(assignment)
    expect(await updateAdminCohortPersonaAssignment(9, 17, 16)).toEqual(assignment)
    await expect(deleteAdminCohortPersonaAssignment(9, 17)).resolves.toBeUndefined()

    expect((fetchMock.mock.calls[2][1] as RequestInit).method).toBe('PATCH')
    expect(JSON.parse(String((fetchMock.mock.calls[2][1] as RequestInit).body))).toEqual({
      persona_assignment: { persona_id: 17, expected_persona_id: 16 },
    })
    expect((fetchMock.mock.calls[3][1] as RequestInit).method).toBe('DELETE')
    expect(JSON.parse(String((fetchMock.mock.calls[3][1] as RequestInit).body))).toEqual({
      persona_assignment: { expected_persona_id: 17 },
    })
  })

  it('preserves structured status, code, errors, and conflicts on an Error subclass', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse({
      error: 'This cohort conflicts with another assignment.',
      errors: ['Reload the current assignment.'],
      code: 'persona_assignment_conflict',
      conflicts: [{ participant_count: 3 }],
    }, 409)))

    const error = await updateAdminCohortPersonaAssignment(9, 17, null).catch((reason: unknown) => reason)

    expect(error).toBeInstanceOf(Error)
    expect(error).toBeInstanceOf(ApiRequestError)
    expect(error).toMatchObject({
      message: 'This cohort conflicts with another assignment.',
      status: 409,
      code: 'persona_assignment_conflict',
      errors: ['Reload the current assignment.'],
      conflicts: [{ participant_count: 3 }],
    })
  })
})

describe('governed content source API contract', () => {
  it('uses private direct upload and revision-bound candidate review endpoints', async () => {
    const candidate = {
      id: 9, source_id: 7, position: 0, status: 'proposed' as const, title: 'One step', kind: 'guidance' as const,
      content: 'Choose one practical next step.', topics: ['planning'], evidence_locator: { type: 'text', segment: 1 },
      evidence_excerpt: 'Choose one practical next step.', revision: 2, digest: 'candidate-digest', safety_code: null,
      accepted_content_item_id: null, reviewed_at: null, updated_at: '2026-10-01T00:00:00Z',
    }
    const source = { id: 7, status: 'needs_review', candidates: [candidate] }
    const permissions = { upload_coach: true, upload_platform: false, retry_cleanup: false }
    const item = { id: 12, title: 'One step' }
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ sources: [source], permissions }))
      .mockResolvedValueOnce(jsonResponse({ source }))
      .mockResolvedValueOnce(jsonResponse({ upload_url: 'https://private.example/source', upload_headers: { 'x-amz-server-side-encryption': 'AES256' }, upload_token: 'bound-token' }))
      .mockResolvedValueOnce(new Response(null, { status: 200 }))
      .mockResolvedValueOnce(jsonResponse({ source }, 201))
      .mockResolvedValueOnce(jsonResponse({ candidate: { ...candidate, revision: 3 } }))
      .mockResolvedValueOnce(jsonResponse({ candidate: { ...candidate, status: 'accepted' }, item }))
      .mockResolvedValueOnce(jsonResponse({ candidate: { ...candidate, status: 'rejected' } }))
      .mockResolvedValueOnce(jsonResponse({ source: { ...source, status: 'queued' } }))
      .mockResolvedValueOnce(jsonResponse({ source: { ...source, status: 'deletion_pending' } }, 202))
      .mockResolvedValueOnce(jsonResponse({ retried_count: 2 }))
    vi.stubGlobal('fetch', fetchMock)

    expect(await fetchAdminContentSources()).toEqual({ sources: [source], permissions })
    expect(await fetchAdminContentSource(7)).toEqual(source)
    expect(await uploadAdminContentSource(new File(['lesson'], 'lesson.txt', { type: 'text/plain' }), 'coach')).toEqual(source)
    await updateAdminContentSourceCandidate(7, candidate, { title: 'One next step', kind: 'guidance', content: candidate.content, topics: candidate.topics })
    await acceptAdminContentSourceCandidate(7, candidate)
    await rejectAdminContentSourceCandidate(7, candidate)
    await reprocessAdminContentSource(7)
    await deleteAdminContentSource(7)
    expect(await retryAdminContentSourceCleanups()).toBe(2)

    const paths = fetchMock.mock.calls.map((call) => String(call[0]).replace(/^.*\/api/, '/api'))
    expect(paths).toEqual([
      '/api/v1/admin/content_sources',
      '/api/v1/admin/content_sources/7',
      '/api/v1/admin/content_sources/presign',
      'https://private.example/source',
      '/api/v1/admin/content_sources/complete',
      '/api/v1/admin/content_sources/7/candidates/9',
      '/api/v1/admin/content_sources/7/candidates/9/accept',
      '/api/v1/admin/content_sources/7/candidates/9/reject',
      '/api/v1/admin/content_sources/7/reprocess',
      '/api/v1/admin/content_sources/7/source',
      '/api/v1/admin/content_sources/retry_upload_cleanups',
    ])
    expect(JSON.parse(String((fetchMock.mock.calls[5][1] as RequestInit).body))).toEqual({
      candidate: { title: 'One next step', kind: 'guidance', content: candidate.content, topics: candidate.topics, revision: 2, digest: 'candidate-digest' },
    })
    expect((fetchMock.mock.calls[9][1] as RequestInit).method).toBe('DELETE')
  })

  it('keeps the current candidate payload on review conflicts and safety responses', async () => {
    const candidate = {
      id: 9, source_id: 7, position: 0, status: 'proposed' as const, title: 'Current server title', kind: 'guidance' as const,
      content: 'Current server wording.', topics: [], evidence_locator: { type: 'text', segment: 1 }, evidence_excerpt: 'Evidence',
      revision: 3, digest: 'server-digest', safety_code: null, accepted_content_item_id: null, reviewed_at: null,
      updated_at: '2026-10-01T00:00:00Z',
    }
    vi.stubGlobal('fetch', vi.fn()
      .mockResolvedValueOnce(jsonResponse({ error: 'Candidate changed.', code: 'content_candidate_conflict', candidate }, 409))
      .mockResolvedValueOnce(jsonResponse({ error: 'Personal information found.', code: 'personal_information', candidate: { ...candidate, safety_code: 'personal_information' } }, 422)))

    const conflict = await updateAdminContentSourceCandidate(7, { ...candidate, revision: 2, digest: 'stale' }, {
      title: 'Local title', kind: 'guidance', content: 'Local wording.', topics: [],
    }).catch((reason: unknown) => reason)
    expect(conflict).toBeInstanceOf(ApiRequestError)
    expect(conflict).toMatchObject({ status: 409, payload: { candidate } })

    const unsafe = await updateAdminContentSourceCandidate(7, candidate, {
      title: candidate.title, kind: candidate.kind, content: 'Contact jane@example.com.', topics: [],
    }).catch((reason: unknown) => reason)
    expect(unsafe).toBeInstanceOf(ApiRequestError)
    expect(unsafe).toMatchObject({ status: 422, code: 'personal_information', payload: { candidate: { safety_code: 'personal_information' } } })
  })
})

describe('safe read deadlines', () => {
  it('ends a stalled workspace read so the loading screen can offer a retry', async () => {
    vi.useFakeTimers()
    let requestSignal: AbortSignal | null | undefined
    const fetchMock = vi.fn((_input: RequestInfo | URL, init?: RequestInit) => {
      requestSignal = init?.signal
      return new Promise<Response>(() => undefined)
    })
    vi.stubGlobal('fetch', fetchMock)

    const workspaceRequest = fetchAppData(true)
    const result = expect(workspaceRequest).rejects.toThrow('This request took too long. Please try again.')
    await vi.advanceTimersByTimeAsync(30_000)
    await result

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(requestSignal?.aborted).toBe(true)
  })

  it('keeps the deadline active while a successful response body is still loading', async () => {
    vi.useFakeTimers()
    let requestSignal: AbortSignal | null | undefined
    const fetchMock = vi.fn((_input: RequestInfo | URL, init?: RequestInit) => {
      requestSignal = init?.signal
      return Promise.resolve(new Response(new ReadableStream({
        start() {
          // Leave the JSON body open to reproduce a server that sent headers and then stalled.
        },
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
    })
    vi.stubGlobal('fetch', fetchMock)

    const workspaceRequest = fetchAppData(true)
    const result = expect(workspaceRequest).rejects.toThrow('This request took too long. Please try again.')
    await vi.advanceTimersByTimeAsync(30_000)
    await result

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(requestSignal?.aborted).toBe(true)
  })

  it('keeps the deadline active while an HTTP error body is still loading', async () => {
    vi.useFakeTimers()
    const fetchMock = vi.fn(() => Promise.resolve(new Response(new ReadableStream({
      start() {
        // Leave the error payload open so apiRequestError cannot finish parsing it.
      },
    }), { status: 503, headers: { 'Content-Type': 'application/json' } })))
    vi.stubGlobal('fetch', fetchMock)

    const workspaceRequest = fetchAppData(true)
    const result = expect(workspaceRequest).rejects.toThrow('This request took too long. Please try again.')
    await vi.advanceTimersByTimeAsync(30_000)
    await result

    expect(fetchMock).toHaveBeenCalledTimes(1)
  })
})

describe('Mia request idempotency polling', () => {
  it('polls an in-flight request with the same request ID until the cached response is ready', async () => {
    vi.useFakeTimers()
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({
        status: 'processing',
        code: 'mia_request_processing',
        retry_after_ms: 100,
      }), { status: 202, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify(completedPayload), {
        status: 201,
        headers: { 'Content-Type': 'application/json' },
      }))
    vi.stubGlobal('fetch', fetchMock)

    const responsePromise = sendMiaMessage('Hello', [], true, 2026, 9, [], 'mia-request-stable-1')
    await vi.advanceTimersByTimeAsync(100)
    const response = await responsePromise

    expect(response.assistant_message.content).toBe('Verified reply')
    expect(fetchMock).toHaveBeenCalledTimes(2)
    const requestBodies = fetchMock.mock.calls.map((call) => JSON.parse(String((call[1] as RequestInit).body)))
    expect(requestBodies.map((body) => body.request_id)).toEqual([
      'mia-request-stable-1',
      'mia-request-stable-1',
    ])
  })

  it('surfaces conflicting request reuse instead of silently creating a new turn', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify({
      code: 'mia_request_conflict',
      error: 'This Mia request ID was already used for different content.',
    }), { status: 409, headers: { 'Content-Type': 'application/json' } })))

    await expect(sendMiaMessage('Edited', [], true, 2026, 9, [], 'mia-request-conflict-1'))
      .rejects.toThrow('already used for different content')
  })

  it('surfaces a failed request as a terminal safe error without polling forever', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({
      status: 'failed',
      code: 'mia_request_failed',
      error: 'Mia could not finish that request safely. Your approved household numbers were not changed; send the message again.',
    }), { status: 503, headers: { 'Content-Type': 'application/json' } }))
    vi.stubGlobal('fetch', fetchMock)

    await expect(sendMiaMessage('Hello', [], true, 2026, 9, [], 'mia-request-failed-1'))
      .rejects.toThrow('approved household numbers were not changed')
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('ends a stalled request and keeps the caller request ID available for a safe retry', async () => {
    vi.useFakeTimers()
    const fetchMock = vi.fn()
      .mockImplementationOnce((_input: RequestInfo | URL, init?: RequestInit) => new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true })
      }))
      .mockResolvedValueOnce(jsonResponse(completedPayload, 201))
    vi.stubGlobal('fetch', fetchMock)

    const firstAttempt = sendMiaMessage('Hello', [], true, 2026, 9, [], 'mia-request-timeout-1')
    const firstResult = expect(firstAttempt).rejects.toThrow('Mia took too long to finish this request. Please try again.')
    await vi.advanceTimersByTimeAsync(90_000)
    await firstResult

    await expect(sendMiaMessage('Hello', [], true, 2026, 9, [], 'mia-request-timeout-1'))
      .resolves.toMatchObject({ assistant_message: { content: 'Verified reply' } })

    const requestBodies = fetchMock.mock.calls.map((call) => JSON.parse(String((call[1] as RequestInit).body)))
    expect(requestBodies.map((body) => body.request_id)).toEqual([
      'mia-request-timeout-1',
      'mia-request-timeout-1',
    ])
  })

  it('includes stalled auth token acquisition in the Mia request deadline', async () => {
    vi.useFakeTimers()
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    setAuthTokenGetter(() => new Promise<string | null>(() => undefined))

    const request = sendMiaMessage('Hello', [], true, 2026, 9, [], 'mia-request-auth-timeout-1')
    const result = expect(request).rejects.toThrow('Mia took too long to finish this request. Please try again.')
    await vi.advanceTimersByTimeAsync(90_000)
    await result

    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('applies the same Mia deadline to the demo conversation', async () => {
    vi.useFakeTimers()
    let requestSignal: AbortSignal | null | undefined
    const fetchMock = vi.fn((_input: RequestInfo | URL, init?: RequestInit) => {
      requestSignal = init?.signal
      return new Promise<Response>(() => undefined)
    })
    vi.stubGlobal('fetch', fetchMock)

    const request = sendMiaMessage('Can I afford this?', [], false)
    const result = expect(request).rejects.toThrow('Mia took too long to finish this request. Please try again.')
    await vi.advanceTimersByTimeAsync(90_000)
    await result

    expect(String(fetchMock.mock.calls[0][0])).toContain('/api/demo/mia/messages')
    expect(requestSignal?.aborted).toBe(true)
  })
})

describe('private document upload', () => {
  it('uploads bytes directly to the presigned storage URL before registering the document', async () => {
    const documentImport = { id: 42, status: 'uploaded', filename: 'budget.csv' }
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({
        upload_url: 'https://private-storage.example/upload',
        upload_headers: { 'Content-Type': 'text/csv', 'x-amz-server-side-encryption': 'AES256' },
        upload_token: 'signed-upload-token',
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response('', { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ document_import: documentImport }), { status: 201, headers: { 'Content-Type': 'application/json' } }))
    vi.stubGlobal('fetch', fetchMock)

    const result = await uploadDocumentImport(new File(['type,label,amount\nincome,Pay,5000'], 'budget.csv', { type: 'text/csv' }), 'spreadsheet')

    expect(result.id).toBe(42)
    expect(fetchMock).toHaveBeenCalledTimes(3)
    expect(String(fetchMock.mock.calls[0][0])).toContain('/api/v1/document_imports/presign')
    expect(JSON.parse(String((fetchMock.mock.calls[0][1] as RequestInit).body)).checksum_sha256).toBe('4cfe69bb4e953d676b7517da64886344a4b1d09db8a03c7852e506f4d09b53ce')
    expect(fetchMock.mock.calls[1][0]).toBe('https://private-storage.example/upload')
    expect((fetchMock.mock.calls[1][1] as RequestInit).method).toBe('PUT')
    expect((fetchMock.mock.calls[1][1] as RequestInit).body).toBeInstanceOf(File)
    expect((fetchMock.mock.calls[1][1] as RequestInit).headers).toEqual({
      'Content-Type': 'text/csv',
      'x-amz-server-side-encryption': 'AES256',
    })
    expect(String(fetchMock.mock.calls[2][0])).toContain('/api/v1/document_imports/complete')
    expect(JSON.parse(String((fetchMock.mock.calls[2][1] as RequestInit).body))).toEqual({ upload_token: 'signed-upload-token' })
  })

  it('uses the canonical extension MIME type when the browser reports a nonstandard CSV type', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({
        upload_url: 'https://private-storage.example/upload',
        upload_headers: { 'Content-Type': 'text/csv' },
        upload_token: 'signed-upload-token',
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response('', { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ document_import: { id: 43 } }), { status: 201, headers: { 'Content-Type': 'application/json' } }))
    vi.stubGlobal('fetch', fetchMock)

    await uploadDocumentImport(new File(['amount\n10'], 'budget.csv', { type: 'text/comma-separated-values' }), 'spreadsheet')

    const presignBody = JSON.parse(String((fetchMock.mock.calls[0][1] as RequestInit).body))
    expect(presignBody.content_type).toBe('text/csv')
    expect((fetchMock.mock.calls[1][1] as RequestInit).headers).toEqual({ 'Content-Type': 'text/csv' })
  })
})
