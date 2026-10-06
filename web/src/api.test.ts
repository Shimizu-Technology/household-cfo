import { afterEach, describe, expect, it, vi } from 'vitest'
import type { AdminApprovedPhrase, AdminPhraseProposal } from './api'
import {
  ApiRequestError,
  transcribeMiaVoice,
  submitPilotFeedback,
  archiveAdminPersona,
  approveAdminContentItem,
  createAdminContentItem,
  createAdminContentPack,
  createAdminPersona,
  createAdminPersonaEvaluationCase,
  createAdminPersonaSetupTurn,
  createAdminPhraseProposal,
  createBudgetCategory,
  createIncomeScheduleEntry,
  createIncomeSource,
  acceptAdminContentSourceCandidate,
  createAdminContentSourceUrlIntake,
  createAdminContentSourceUrlRequestId,
  createCohortReleaseRequestId,
  createCohortRolloutRequestId,
  deleteAdminContentSource,
  deleteAdminContentSourceUrlIntake,
  deleteAdminCohortPersonaAssignment,
  fetchAppData,
  fetchAdminCohortPersonaAssignment,
  fetchAdminPersona,
  fetchAdminPersonaAssignableCohorts,
  fetchAdminPersonas,
  fetchAdminPersonaVersion,
  fetchAdminPersonaReleaseReadiness,
  fetchAdminPersonaEvaluationCases,
  fetchAdminPersonaEvaluationRuns,
  fetchAdminPersonaEvaluationRun,
  fetchAdminContentItems,
  fetchAdminContentPacks,
  fetchAdminContentSource,
  fetchDocumentImportSourceContent,
  fetchDocumentImportSourceUrl,
  fetchAdminContentSourceUrlIntake,
  fetchAdminContentSourceUrlIntakes,
  fetchAdminContentSources,
  fetchCohortReleaseStudio,
  fetchCohortRolloutStudio,
  fetchPublicBrand,
  fetchAdminContentSourcePhraseProposals,
  fetchAdminPhraseProposal,
  previewAdminPersona,
  publishAdminPersona,
  runAdminPersonaEvaluation,
  reviewAdminPersonaEvaluation,
  reviewAdminPersonaAudience,
  retireAdminPersonaEvaluationCase,
  publishAdminContentPack,
  restoreAdminPersona,
  restoreAdminPhrasePromotion,
  resolveAdminPersonaSetupProposal,
  rejectAdminContentSourceCandidate,
  reprocessAdminContentSource,
  retryAdminContentSourceCleanups,
  retryAdminContentSourceUrlIntakeCleanup,
  restoreAdminPersonaVersionToDraft,
  restoreCohortRelease,
  advanceCohortRollout,
  cancelCohortRollout,
  pauseCohortRollout,
  planCohortRollout,
  resumeCohortRollout,
  rollbackCohortRollout,
  sealCohortRelease,
  sendMiaMessage,
  setActiveCoachWorkspaceId,
  setAuthTokenGetter,
  updateAdminCohortPersonaAssignment,
  updateAdminPersona,
  updateAdminContentItem,
  updateAdminContentPack,
  updateAdminContentSourceCandidate,
  updateAdminPhraseProposal,
  updateAdminPersonaContentPacks,
  uploadDocumentImport,
  uploadAdminContentSource,
  updateBudgetAllocation,
  updateIncomeScheduleEntry,
  updateIncomeSource,
  archiveIncomeSource,
  attestAdminPhraseProposal,
  bulkConfirmTransactionDrafts,
  browserBrandHostname,
  confirmTransactionDraft,
  restoreIncomeSource,
  deleteIncomeScheduleEntry,
  matchTransactionDraft,
  reopenTransactionDraft,
  saveWorkspaceSetup,
  submitAdminPhraseProposal,
  promoteAdminPhraseProposal,
  updateTransactionDraft,
} from './api'

const publicBrandPayload = {
  brand: {
    schema_version: 1,
    product_name: 'Island Money Lab',
    short_name: 'Island Lab',
    organization_name: 'Mel Coaching',
    participant_role_term: 'member',
    powered_by_name: 'VERA',
    powered_by_placement: 'footer',
    tagline: 'Money guidance rooted in community',
    welcome_heading: 'Håfa adai',
    welcome_description: 'Your coaching space is ready.',
    logo_url: null,
    favicon_url: null,
    support: { label: 'Ask Mel', email: 'mel@example.com', url: null },
    colors: {
      background: '#f7f2ea', surface: '#fffdf8', surface_muted: '#fbf7ef', text: '#1f2421', text_muted: '#706d66', border: '#e2d9cb',
      primary: '#536a63', primary_hover: '#3f524c', primary_soft: '#e5ece9', accent: '#9a7457', on_primary: '#ffffff', focus: '#536a63',
    },
    typography: { display: 'system_serif', body: 'system_sans' },
    footer: { text: 'Island Money Lab', privacy_url: null, terms_url: null },
  },
  source: 'active_domain',
  available: true,
  workspace: { slug: 'island-money' },
  version: { number: 3, digest: 'brand-digest' },
  primary_domain: 'coach.example.test',
}

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

describe('public brand bootstrap boundary', () => {
  it('loads a public brand without credentials or workspace headers', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(publicBrandPayload))
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchPublicBrand('Coach.Example.Test')

    expect(result.brand.product_name).toBe('Island Money Lab')
    expect(String(fetchMock.mock.calls[0][0])).toContain('hostname=coach.example.test')
    expect(fetchMock.mock.calls[0][1]).toMatchObject({ credentials: 'omit' })
    expect((fetchMock.mock.calls[0][1] as RequestInit).headers).toBeUndefined()
  })

  it('accepts a neutral 404 contract and rejects corrupt JSON without leaking parser details', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ ...publicBrandPayload, available: false, source: 'safe_default', workspace: null, version: null, primary_domain: null }, 404))
      .mockResolvedValueOnce(new Response('{broken', { status: 200, headers: { 'Content-Type': 'application/json' } }))
    vi.stubGlobal('fetch', fetchMock)

    await expect(fetchPublicBrand('unknown.example.test')).resolves.toMatchObject({ available: false, source: 'safe_default' })
    await expect(fetchPublicBrand('broken.example.test')).rejects.toThrow('The coaching program returned an invalid brand configuration.')
  })
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
      expect(((call[1] as RequestInit).headers as Record<string, string>)['X-Brand-Hostname']).toBe(browserBrandHostname())
    }
  })
})

describe('persona setup idempotency contract', () => {
  it('sends caller-owned keys for turns and both proposal resolutions', async () => {
    const session = { id: 8, turns: [], proposal: null }
    const fetchMock = vi.fn().mockImplementation(async () => jsonResponse({ session }))
    vi.stubGlobal('fetch', fetchMock)
    setActiveCoachWorkspaceId(42)

    await createAdminPersonaSetupTurn(7, 8, 'Use my exact words.', 'setup-turn-attempt')
    await resolveAdminPersonaSetupProposal(7, 8, 9, 'apply', 'setup-apply-attempt')
    await resolveAdminPersonaSetupProposal(7, 8, 9, 'reject', 'setup-reject-attempt')

    expect(fetchMock.mock.calls.map((call) => ((call[1] as RequestInit).headers as Record<string, string>)['Idempotency-Key'])).toEqual([
      'setup-turn-attempt', 'setup-apply-attempt', 'setup-reject-attempt',
    ])
    expect(fetchMock.mock.calls.map((call) => String(call[0]).replace(/^.*\/api/, '/api'))).toEqual([
      '/api/v1/admin/personas/7/setup_sessions/8/turns',
      '/api/v1/admin/personas/7/setup_sessions/8/proposals/9/apply',
      '/api/v1/admin/personas/7/setup_sessions/8/proposals/9/reject',
    ])
  })
})

describe('cohort release API contract', () => {
  it('normalizes nested readiness evidence and sends exact idempotent seal and restore inputs', async () => {
    const releasePayload = {
      cohort_release_studio: {
        cohort: { id: 12, name: 'Tuesday cohort', status: 'active' },
        runtime_truth: { changes_participant_runtime: false, message: 'Audit evidence only.' },
        permissions: { view: true, seal: true, restore: true },
        readiness: {
          ready: true,
          seal_needed: true,
          latest_release_match: false,
          expected_latest_release_id: 44,
          blockers: [],
          warnings: ['Review the roster.'],
          checks: [{ key: 'persona', label: 'Assistant voice', ready: true, detail: 'Version 6' }],
          candidate: {
            manifest_schema: 'cohort_release_manifest_v2',
            bundle_digest: 'bundle-next',
            assignment_id: 31,
            coach_persona_version_id: 6,
            cohort_experience_version_id: 8,
            brand_mode: 'published_version',
            workspace_brand_version_id: 9,
            brand_snapshot_digest: 'brand-v9',
            tool_registry_digest: 'registry-v3',
            tool_registry_version: 3,
          },
        },
        history: { limit: 25, total_count: 100, truncated: true },
        releases: [{
          id: 44,
          release_number: 4,
          event_type: 'release',
          released_at: '2026-10-03T01:00:00Z',
          actor_user_id: 7,
          manifest_schema: 'cohort_release_manifest_v1',
          bundle_digest: 'bundle-old',
          coach_persona_version_id: 5,
          cohort_experience_version_id: 7,
          brand_mode: 'legacy_household_cfo_builtin',
          workspace_brand_version_id: null,
          brand_snapshot_digest: '35ded27bda2348d56c1db078c087ed681442a4a7bba86d8924c39a9342fa7eb8',
          tool_registry_digest: 'registry-v2',
          tool_registry_version: 2,
          restore_allowed: false,
          restore_blockers: ['The assistant is archived.', 'Choose another record.'],
        }],
      },
    }
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse(releasePayload))
      .mockResolvedValueOnce(jsonResponse({ release: { id: 45 } }, 201))
      .mockResolvedValueOnce(jsonResponse({ release: { id: 46 } }, 201))
    vi.stubGlobal('fetch', fetchMock)

    const studio = await fetchCohortReleaseStudio(12)
    expect(studio.candidate).toMatchObject({
      bundle_digest: 'bundle-next',
      persona_version_id: 6,
      experience_version_id: 8,
      brand_mode: 'published_version',
      brand_version_id: 9,
      brand_snapshot_digest: 'brand-v9',
      registry_digest: 'registry-v3',
      registry_version: 3,
      expected_latest_release_id: 44,
      ready: true,
      seal_needed: true,
    })
    expect(studio.releases[0]).toMatchObject({
      actor_user_id: 7,
      manifest_schema: 'cohort_release_manifest_v1',
      brand_mode: 'legacy_household_cfo_builtin',
      brand_version_id: null,
      restore_reason: 'The assistant is archived. Choose another record.',
    })
    expect(studio.history).toEqual({ limit: 25, total_count: 100, truncated: true })

    await sealCohortRelease(12, {
      expected_bundle_digest: 'bundle-next',
      expected_assignment_id: 31,
      expected_persona_version_id: 6,
      expected_experience_version_id: 8,
      expected_brand_version_id: 9,
      expected_tool_registry_digest: 'registry-v3',
      expected_tool_registry_version: 3,
      expected_latest_release_id: 44,
    }, 'seal-attempt')
    await restoreCohortRelease(12, 44, {
      expected_latest_release_id: 44,
      source_bundle_digest: 'bundle-old',
      source_persona_version_id: 5,
      source_experience_version_id: 7,
      source_brand_version_id: null,
    }, 'restore-attempt')

    expect(createCohortReleaseRequestId()).toBeTruthy()
    expect(fetchMock.mock.calls.slice(1).map((call) => String(call[0]).replace(/^.*\/api/, '/api'))).toEqual([
      '/api/v1/admin/cohorts/12/releases',
      '/api/v1/admin/cohorts/12/releases/44/restore',
    ])
    expect(fetchMock.mock.calls.slice(1).map((call) => ((call[1] as RequestInit).headers as Record<string, string>)['Idempotency-Key'])).toEqual([
      'seal-attempt', 'restore-attempt',
    ])
    expect(JSON.parse(String((fetchMock.mock.calls[2][1] as RequestInit).body))).toEqual({
      release: {
        expected_latest_release_id: 44,
        source_bundle_digest: 'bundle-old',
        source_persona_version_id: 5,
        source_experience_version_id: 7,
        source_brand_version_id: null,
      },
    })
  })
})

describe('cohort rollout API contract', () => {
  it('normalizes rollout evidence and sends exact stable-key lifecycle inputs', async () => {
    const baselineRelease = { id: 43, release_number: 3, bundle_digest: 'baseline-bundle', manifest_schema: 'cohort_release_manifest_v2', brand_mode: 'published_version', workspace_brand_version_id: 8, brand_snapshot_digest: 'brand-v8', integrity_valid: true, runtime_compatible: true, released_at: '2026-10-02T01:00:00Z' }
    const targetRelease = { id: 44, release_number: 4, bundle_digest: 'bundle', manifest_schema: 'cohort_release_manifest_v2', brand_mode: 'published_version', workspace_brand_version_id: 9, brand_snapshot_digest: 'brand-v9', integrity_valid: true, runtime_compatible: true, released_at: '2026-10-03T01:00:00Z' }
    const rolloutPayload = {
      cohort_rollout_studio: {
        cohort: { id: 12, name: 'Tuesday cohort', status: 'active', participant_count: 2 },
        runtime_truth: { changes_participant_runtime: true, participant_runtime_changed: false, message: 'Advancing a wave changes participant runtime immediately.' },
        permissions: { view: true, manage: true, plan: false, actor_role: 'owner', blockers: [], plan_blockers: ['Another rollout is already open.'] },
        current_roster: {
          digest: 'roster-digest', readiness_digest: 'roster-ready', total_count: 2,
          counts: { ready: 2, awaiting_acceptance: 0, revoked: 0, removed: 0 },
          participants: [{ user_id: 7, full_name: 'Ana Cruz', readiness: 'ready', exposed: false, effective_release: baselineRelease }, { user_id: 8, full_name: 'Ben Santos', readiness: 'ready', exposed: false, effective_release: baselineRelease }],
        },
        active_release: baselineRelease,
        latest_release: targetRelease,
        release_history: { limit: 25, total_count: 4, truncated: false }, releases: [],
        history: { limit: 25, total_count: 1, truncated: false },
        open_rollout: {
          id: 90, status: 'planned',
          runtime_mode: 'release_runtime_v2', runtime_blocker: null,
          target_release: targetRelease, baseline_release: baselineRelease,
          rollback_release: null, rollback_candidate: null,
          planned_by: { id: 5, full_name: 'Coach Mel', role: 'owner' }, planned_at: '2026-10-03T02:00:00Z',
          activated_at: null, paused_at: null, completed_at: null, cancelled_at: null, rolled_back_at: null,
          current_wave_position: 0, wave_count: 1, participant_count: 2, latest_transition_id: 101,
          readiness_digest: 'all-ready', next_wave_readiness_digest: 'wave-ready', next_wave_position: 1,
          permissions: { advance: true, pause: false, resume: false, cancel: true, rollback: false, advance_blockers: [], rollback_blockers: ['Only active rollouts can roll back.'] },
          waves: [{ id: 91, position: 1, name: 'All participants', active: false, completed: false, participant_count: 2, exposed_count: 0, exposure_complete: false, counts: { ready: 2, awaiting_acceptance: 0, revoked: 0, removed: 0 }, participants: [{ user_id: 7, full_name: 'Ana Cruz', readiness: 'ready', exposed: false, effective_release: baselineRelease }, { user_id: 8, full_name: 'Ben Santos', readiness: 'ready', exposed: false, effective_release: baselineRelease }] }],
          transition_history: { limit: 25, total_count: 1, truncated: false },
          transitions: [{ id: 101, event_type: 'planned', from_status: null, to_status: 'planned', from_wave_position: 0, to_wave_position: 0, rollback_release_id: null, readiness_digest: null, actor: { id: 5, full_name: 'Coach Mel', role: 'owner' }, occurred_at: '2026-10-03T02:00:00Z', participant_runtime_changed: false }],
          participant_runtime_changed: false,
        },
        rollouts: [{ id: 90, status: 'planned', runtime_mode: 'release_runtime_v2', runtime_blocker: null, target_release: targetRelease, baseline_release: baselineRelease, rollback_release: null, planned_by: { id: 5, full_name: 'Coach Mel', role: 'owner' }, planned_at: '2026-10-03T02:00:00Z', activated_at: null, paused_at: null, completed_at: null, cancelled_at: null, rolled_back_at: null, current_wave_position: 0, wave_count: 1, participant_count: 2, participant_runtime_changed: false }],
      },
    }
    const mutationPayload = {
      ...rolloutPayload,
      rollout: rolloutPayload.cohort_rollout_studio.open_rollout,
      transition: rolloutPayload.cohort_rollout_studio.open_rollout.transitions[0],
      replayed: false,
    }
    const fetchMock = vi.fn().mockImplementation(async (_input, init?: RequestInit) => jsonResponse(init?.method === 'POST' ? mutationPayload : rolloutPayload))
    vi.stubGlobal('fetch', fetchMock)

    const studio = await fetchCohortRolloutStudio(12)
    expect(studio.open_rollout).toMatchObject({
      id: 90, status: 'planned', latest_transition_id: 101, next_wave_readiness_digest: 'wave-ready',
      runtime_mode: 'release_runtime_v2', baseline_release: { release_number: 3 },
      waves: [{ name: 'All participants', exposed_count: 0, exposure_complete: false, participants: [{ full_name: 'Ana Cruz', effective_release: { release_number: 3 } }, { full_name: 'Ben Santos', effective_release: { release_number: 3 } }] }],
    })
    expect(studio.active_release?.release_number).toBe(3)

    const compare = { expected_status: 'planned', expected_current_wave_position: 0, expected_latest_transition_id: 101 }
    const plan = { target_release_id: 44, expected_latest_release_id: 44, expected_roster_digest: 'roster-digest', waves: [{ name: 'All participants', user_ids: [7, 8] }] }
    expect((await planCohortRollout(12, plan, 'plan-key')).transition.participant_runtime_changed).toBe(false)
    expect((await advanceCohortRollout(12, 90, { ...compare, readiness_digest: 'wave-ready' }, 'advance-key')).rollout.runtime_mode).toBe('release_runtime_v2')
    await pauseCohortRollout(12, 90, compare, 'pause-key')
    await resumeCohortRollout(12, 90, compare, 'resume-key')
    await cancelCohortRollout(12, 90, compare, 'cancel-key')
    await rollbackCohortRollout(12, 90, { ...compare, rollback_release_id: 43 }, 'rollback-key')

    expect(createCohortRolloutRequestId()).toBeTruthy()
    expect(fetchMock.mock.calls.slice(1).map((call) => String(call[0]).replace(/^.*\/api/, '/api'))).toEqual([
      '/api/v1/admin/cohorts/12/rollouts',
      '/api/v1/admin/cohorts/12/rollouts/90/advance',
      '/api/v1/admin/cohorts/12/rollouts/90/pause',
      '/api/v1/admin/cohorts/12/rollouts/90/resume',
      '/api/v1/admin/cohorts/12/rollouts/90/cancel',
      '/api/v1/admin/cohorts/12/rollouts/90/rollback',
    ])
    expect(fetchMock.mock.calls.slice(1).map((call) => ((call[1] as RequestInit).headers as Record<string, string>)['Idempotency-Key'])).toEqual([
      'plan-key', 'advance-key', 'pause-key', 'resume-key', 'cancel-key', 'rollback-key',
    ])
    expect(JSON.parse(String((fetchMock.mock.calls[6][1] as RequestInit).body))).toEqual({ rollout: { ...compare, rollback_release_id: 43 } })

    const futurePayload = structuredClone(rolloutPayload)
    futurePayload.cohort_rollout_studio.open_rollout.runtime_mode = 'future_mode'
    futurePayload.cohort_rollout_studio.rollouts[0].runtime_mode = 'future_mode'
    fetchMock.mockResolvedValueOnce(jsonResponse(futurePayload))
    const failClosedStudio = await fetchCohortRolloutStudio(12)
    expect(failClosedStudio.open_rollout?.runtime_mode).toBe('future_mode')
    expect(failClosedStudio.rollouts[0].runtime_mode).toBe('future_mode')
    expect(failClosedStudio.open_rollout?.permissions).toMatchObject({ advance: false, pause: false, resume: false, cancel: false, rollback: false })
    expect(failClosedStudio.open_rollout?.permissions.advance_blockers).toContain('This app does not recognize the rollout runtime mode. Reload after updating the app.')
  })

  it('bounds a stalled mutation and preserves the caller-owned retry key', async () => {
    vi.useFakeTimers()
    let requestSignal: AbortSignal | null | undefined
    const fetchMock = vi.fn((_input: RequestInfo | URL, init?: RequestInit) => {
      requestSignal = init?.signal
      return new Promise<Response>(() => undefined)
    })
    vi.stubGlobal('fetch', fetchMock)
    const compare = { expected_status: 'active', expected_current_wave_position: 1, expected_latest_transition_id: 101 }

    const request = pauseCohortRollout(12, 90, compare, 'stable-pause-key')
    const result = expect(request).rejects.toThrow('The rollout request took too long. Retry this reviewed action; the same request key prevents a duplicate decision.')
    await vi.advanceTimersByTimeAsync(30_000)
    await result

    expect(requestSignal?.aborted).toBe(true)
    expect((fetchMock.mock.calls[0][1] as RequestInit).headers).toMatchObject({ 'Idempotency-Key': 'stable-pause-key' })
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

    await createBudgetCategory({ name: 'Dining', stack_key: 'discretionary', monthly_amount: 250, month_numbers: [1, 2, 3] }, 2026, 'category-attempt')
    await updateBudgetAllocation(44, 325, 'allocation-attempt')

    expect((fetchMock.mock.calls[0][1] as RequestInit).headers).toMatchObject({ 'Idempotency-Key': 'category-attempt' })
    expect(JSON.parse(String((fetchMock.mock.calls[0][1] as RequestInit).body))).toEqual({
      category: { name: 'Dining', stack_key: 'discretionary', monthly_amount: 250, month_numbers: [1, 2, 3] },
    })
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
  it('creates and retires immutable custom evaluation cases with typed assertions', async () => {
    const evaluationCase = { id: 4, kind: 'custom', name: 'Event decision', active: true }
    const retiredCase = { ...evaluationCase, active: false, retired_at: '2026-10-02T00:00:00Z' }
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ evaluation_case: evaluationCase, reconciliation: { request_id: 'case-request', replayed: false } }, 201))
      .mockResolvedValueOnce(jsonResponse({ evaluation_case: retiredCase }))
    vi.stubGlobal('fetch', fetchMock)

    expect(await createAdminPersonaEvaluationCase(17, {
      request_id: 'case-request', name: 'Event decision', prompt: 'Can I attend this fictional event?',
      assertions: [{ type: 'includes_any', values: ['budget', 'tradeoff'] }, { type: 'max_chars', value: 1200 }, { type: 'not_fallback' }],
    })).toEqual({ evaluation_case: evaluationCase, reconciliation: { request_id: 'case-request', replayed: false } })
    expect(await retireAdminPersonaEvaluationCase(17, 4)).toEqual(retiredCase)

    expect(String(fetchMock.mock.calls[0][0])).toContain('/api/v1/admin/personas/17/evaluation_cases')
    expect(JSON.parse(String((fetchMock.mock.calls[0][1] as RequestInit).body))).toEqual({ evaluation_case: {
      request_id: 'case-request', name: 'Event decision', prompt: 'Can I attend this fictional event?',
      assertions: [{ type: 'includes_any', values: ['budget', 'tradeoff'] }, { type: 'max_chars', value: 1200 }, { type: 'not_fallback' }],
    } })
    expect((fetchMock.mock.calls[1][1] as RequestInit).method).toBe('DELETE')
  })

  it('uses exact release readiness, guardrail, review, and audience envelopes', async () => {
    const readiness = { ready: false }
    const evaluationCase = { id: 4, name: 'Identity disclosure' }
    const run = { id: 9, status: 'pending', run_digest: null }
    const approval = { id: 12, decision: 'approved' }
    const audienceAttestation = { id: 15, decision: 'approved' }
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ readiness }))
      .mockResolvedValueOnce(jsonResponse({ evaluation_cases: [evaluationCase] }))
      .mockResolvedValueOnce(jsonResponse({ evaluation_runs: [run] }))
      .mockResolvedValueOnce(jsonResponse({ evaluation_run: run }))
      .mockResolvedValueOnce(jsonResponse({ evaluation_run: run, reconciliation: { request_id: 'run-request', replayed: false, enqueued: true } }, 202))
      .mockResolvedValueOnce(jsonResponse({ approval }, 201))
      .mockResolvedValueOnce(jsonResponse({ audience_attestation: audienceAttestation }, 201))
    vi.stubGlobal('fetch', fetchMock)

    expect(await fetchAdminPersonaReleaseReadiness(17)).toEqual(readiness)
    expect(await fetchAdminPersonaEvaluationCases(17)).toEqual([evaluationCase])
    expect(await fetchAdminPersonaEvaluationRuns(17)).toEqual([run])
    expect(await fetchAdminPersonaEvaluationRun(17, 9)).toEqual(run)
    expect(await runAdminPersonaEvaluation(17, 'run-request')).toEqual({ evaluation_run: run, reconciliation: { request_id: 'run-request', replayed: false, enqueued: true } })
    expect(await reviewAdminPersonaEvaluation(17, 9, 'approved', 'run-digest')).toEqual(approval)
    expect(await reviewAdminPersonaAudience(17, {
      candidate_digest: 'candidate-digest',
      artifact_id: 'phrase-1',
      artifact_fingerprint: 'phrase-fingerprint',
      decision: 'approved',
    })).toEqual(audienceAttestation)

    expect(fetchMock.mock.calls.map((call) => String(call[0]).replace(/^.*\/api/, '/api'))).toEqual([
      '/api/v1/admin/personas/17/release_readiness',
      '/api/v1/admin/personas/17/evaluation_cases',
      '/api/v1/admin/personas/17/evaluation_runs',
      '/api/v1/admin/personas/17/evaluation_runs/9',
      '/api/v1/admin/personas/17/evaluation_runs',
      '/api/v1/admin/personas/17/evaluation_runs/9/approval',
      '/api/v1/admin/personas/17/audience_attestations',
    ])
    expect(JSON.parse(String((fetchMock.mock.calls[4][1] as RequestInit).body))).toEqual({ evaluation_run: { request_id: 'run-request' } })
    expect(JSON.parse(String((fetchMock.mock.calls[5][1] as RequestInit).body))).toEqual({ approval: { decision: 'approved', run_digest: 'run-digest' } })
    expect(JSON.parse(String((fetchMock.mock.calls[6][1] as RequestInit).body))).toEqual({
      audience_attestation: {
        candidate_digest: 'candidate-digest', artifact_id: 'phrase-1', artifact_fingerprint: 'phrase-fingerprint', decision: 'approved',
      },
    })
  })

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
    const behavioralPreviewEvidence = { digest: 'behavioral-preview-digest', valid: true }
    const version = { id: 31, number: 1 }
    const draftRestore = { id: 41, source_version: { id: 31, number: 1 }, previous_draft_revision: 2, restored_draft_revision: 3, digest: 'restore-digest', valid: true }
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ personas: [persona] }))
      .mockResolvedValueOnce(jsonResponse({ persona }))
      .mockResolvedValueOnce(jsonResponse({ persona }, 201))
      .mockResolvedValueOnce(jsonResponse({ persona }))
      .mockResolvedValueOnce(jsonResponse({ persona }))
      .mockResolvedValueOnce(jsonResponse({ persona }))
      .mockResolvedValueOnce(jsonResponse({ persona, preview, behavioral_preview_evidence: behavioralPreviewEvidence }))
      .mockResolvedValueOnce(jsonResponse({ persona, published_version: version }))
      .mockResolvedValueOnce(jsonResponse({ persona, version }))
      .mockResolvedValueOnce(jsonResponse({ persona, draft_restore: draftRestore }))
    vi.stubGlobal('fetch', fetchMock)
    setAuthTokenGetter(async () => 'staff-token')

    expect(await fetchAdminPersonas()).toEqual([persona])
    expect(await fetchAdminPersona(17)).toEqual(persona)
    expect(await createAdminPersona({ name: 'Coach Lani' })).toEqual(persona)
    expect(await updateAdminPersona(17, { draft_revision: 2, description: 'Clear and kind.' })).toEqual(persona)
    expect(await archiveAdminPersona(17)).toEqual(persona)
    expect(await restoreAdminPersona(17)).toEqual(persona)
    expect(await previewAdminPersona(17, 2, 'Can I afford this?')).toEqual({ persona, preview, behavioral_preview_evidence: behavioralPreviewEvidence })
    expect(await publishAdminPersona(17, {
      draft_revision: 2,
      preview_digest: 'preview-digest',
      expected_published_version_id: 30,
      release_candidate_digest: 'candidate-digest',
      evaluation_run_digest: 'run-digest',
      evaluation_approval_digest: 'approval-digest',
      behavioral_preview_digest: 'behavioral-preview-digest',
    })).toEqual({ persona, published_version: version })
    expect(await fetchAdminPersonaVersion(17, 31)).toEqual({ persona, version })
    expect(await restoreAdminPersonaVersionToDraft(17, 31, {
      draft_revision: 2,
      expected_published_version_id: 32,
    })).toEqual({ persona, draft_restore: draftRestore })

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
    expect((fetchMock.mock.calls[2][1] as RequestInit).signal).toBeInstanceOf(AbortSignal)
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
        release_candidate_digest: 'candidate-digest',
        evaluation_run_digest: 'run-digest',
        evaluation_approval_digest: 'approval-digest',
        behavioral_preview_digest: 'behavioral-preview-digest',
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
  it('uses server-side HTTPS snapshot endpoints without fetching the target address in the browser', async () => {
    const intake = {
      id: 41, scope: 'coach' as const, status: 'queued' as const, source_id: null, error_code: null, error: null,
      cleanup_retryable: false, redaction_allowed: false, redaction_pending: false, redirect_count: 0,
      created_at: '2026-10-02T00:00:00Z', completed_at: null,
    }
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ intakes: [intake], url_intake: { enabled: true, available: true } }))
      .mockResolvedValueOnce(jsonResponse({ intake }))
      .mockResolvedValueOnce(jsonResponse({ intake }, 202))
      .mockResolvedValueOnce(jsonResponse({ intake: { ...intake, status: 'cleanup_pending' } }, 202))
      .mockResolvedValueOnce(jsonResponse({ intake: { ...intake, status: 'deleted' } }))
    vi.stubGlobal('fetch', fetchMock)

    await fetchAdminContentSourceUrlIntakes()
    await fetchAdminContentSourceUrlIntake(41)
    await createAdminContentSourceUrlIntake({
      url: 'https://example.com/private?token=secret', requestId: 'stable-request-id', scope: 'coach',
    })
    await retryAdminContentSourceUrlIntakeCleanup(41)
    await deleteAdminContentSourceUrlIntake(41)

    expect(fetchMock.mock.calls.map((call) => String(call[0]).replace(/^.*\/api/, '/api'))).toEqual([
      '/api/v1/admin/content_source_url_intakes?scope=coach',
      '/api/v1/admin/content_source_url_intakes/41',
      '/api/v1/admin/content_source_url_intakes',
      '/api/v1/admin/content_source_url_intakes/41/retry_cleanup',
      '/api/v1/admin/content_source_url_intakes/41',
    ])
    expect(JSON.parse(String((fetchMock.mock.calls[2][1] as RequestInit).body))).toEqual({
      url: 'https://example.com/private?token=secret', request_id: 'stable-request-id', scope: 'coach',
    })
    expect((fetchMock.mock.calls[4][1] as RequestInit).method).toBe('DELETE')
    expect((fetchMock.mock.calls[3][1] as RequestInit).signal).toBeInstanceOf(AbortSignal)
    expect((fetchMock.mock.calls[4][1] as RequestInit).signal).toBeInstanceOf(AbortSignal)
    expect(fetchMock.mock.calls.some((call) => String(call[0]).includes('example.com'))).toBe(false)
    expect(createAdminContentSourceUrlRequestId().length).toBeGreaterThanOrEqual(8)
  })

  it('uses private direct upload and revision-bound candidate review endpoints', async () => {
    const candidate = {
      id: 9, source_id: 7, position: 0, status: 'proposed' as const, title: 'One step', kind: 'guidance' as const,
      content: 'Choose one practical next step.', topics: ['planning'], evidence_locator: { type: 'text', segment: 1 },
      evidence_excerpt: 'Choose one practical next step.', revision: 2, digest: 'candidate-digest', safety_code: null,
      accepted_content_item_id: null, reviewed_at: null, updated_at: '2026-10-01T00:00:00Z',
      accepted_content_item_version_id: null,
      accepted_content_item_version_kind: null, accepted_content_item_version_content: null,
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
      accepted_content_item_version_id: null,
      accepted_content_item_version_kind: null, accepted_content_item_version_content: null,
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

  it('keeps phrase review, attestation, promotion, and restore revision bound', async () => {
    const phrase: AdminApprovedPhrase = {
      text: 'One step at a time', meaning: 'Choose one practical action.', allowed_contexts: ['general'],
      prohibited_contexts: ['crisis'], frequency: 'rare', caution: 'Avoid during urgent safety needs.',
    }
    const proposal: AdminPhraseProposal = {
      id: 31, source_id: 7, source_label: 'coach-source.txt', content_item_version_id: 22, status: 'draft' as const,
      phrase, revision: 4, digest: 'proposal-digest', submitted_at: null, superseded_at: null,
      proposed_by: { id: 2, full_name: 'Coach Editor' }, attestation: null, promotion_count: 0,
      permissions: { edit: true, submit: true, review: false, promote: false },
    }
    const persona = { id: 5, draft_revision: 9 }
    const promotion = { id: 8, persona_id: 5, proposal_id: 31, artifact_id: 'approved-source-31', phrase, source_label: 'coach-source.txt', promoted_at: '2026-10-02T00:00:00Z', promoted_by: { id: 2, full_name: 'Coach Editor' } }
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ phrase_proposals: [proposal], permissions: { view: true, propose: true, review: false, promote: false } }))
      .mockResolvedValueOnce(jsonResponse({ phrase_proposal: proposal }))
      .mockResolvedValueOnce(jsonResponse({ phrase_proposal: proposal }, 201))
      .mockResolvedValueOnce(jsonResponse({ phrase_proposal: { ...proposal, revision: 5 } }))
      .mockResolvedValueOnce(jsonResponse({ phrase_proposal: { ...proposal, status: 'submitted' } }))
      .mockResolvedValueOnce(jsonResponse({ phrase_proposal: { ...proposal, attestation: { decision: 'approved' } } }))
      .mockResolvedValueOnce(jsonResponse({ persona, phrase_promotion: promotion }, 201))
      .mockResolvedValueOnce(jsonResponse({ persona, phrase_promotion: promotion }, 201))
    vi.stubGlobal('fetch', fetchMock)

    await fetchAdminContentSourcePhraseProposals(7)
    await fetchAdminPhraseProposal(31)
    await createAdminPhraseProposal(7, { candidate_id: 9, content_item_version_id: 22, phrase: { ...phrase, allowed_contexts: ['general'], prohibited_contexts: ['crisis'] } })
    await updateAdminPhraseProposal(proposal, { ...phrase, allowed_contexts: ['general'], prohibited_contexts: ['crisis'] })
    await submitAdminPhraseProposal(proposal)
    await attestAdminPhraseProposal(proposal, 'approved')
    await promoteAdminPhraseProposal(5, 31, 9)
    await restoreAdminPhrasePromotion(5, 8, 9)

    expect(fetchMock.mock.calls.map((call) => String(call[0]).replace(/^.*\/api/, '/api'))).toEqual([
      '/api/v1/admin/content_sources/7/phrase_proposals', '/api/v1/admin/phrase_proposals/31',
      '/api/v1/admin/content_sources/7/phrase_proposals', '/api/v1/admin/phrase_proposals/31',
      '/api/v1/admin/phrase_proposals/31/submit', '/api/v1/admin/phrase_proposals/31/attestation',
      '/api/v1/admin/personas/5/phrase_promotions', '/api/v1/admin/personas/5/phrase_promotions/8/restore',
    ])
    expect(JSON.parse(String((fetchMock.mock.calls[3][1] as RequestInit).body))).toEqual({ phrase_proposal: { phrase, revision: 4, digest: 'proposal-digest' } })
    expect(JSON.parse(String((fetchMock.mock.calls[4][1] as RequestInit).body))).toEqual({ phrase_proposal: { revision: 4, digest: 'proposal-digest' } })
    expect(JSON.parse(String((fetchMock.mock.calls[5][1] as RequestInit).body))).toEqual({ attestation: { decision: 'approved', proposal_digest: 'proposal-digest' } })
    expect(JSON.parse(String((fetchMock.mock.calls[6][1] as RequestInit).body))).toEqual({ phrase_promotion: { proposal_id: 31, draft_revision: 9 } })
    expect(JSON.parse(String((fetchMock.mock.calls[7][1] as RequestInit).body))).toEqual({ phrase_promotion: { draft_revision: 9 } })
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

describe('mutation deadlines', () => {
  it('ends a stalled write without retrying a possibly committed change', async () => {
    vi.useFakeTimers()
    let signal: AbortSignal | null | undefined
    const fetchMock = vi.fn((_input: RequestInfo | URL, init?: RequestInit) => {
      signal = init?.signal
      return new Promise<Response>(() => undefined)
    })
    vi.stubGlobal('fetch', fetchMock)
    const operation = createBudgetCategory({ name: 'Meals', stack_key: 'discretionary', monthly_amount: 50 }, 2026, 'stalled-category')
    const result = expect(operation).rejects.toThrow('Refresh to check the current state before trying again.')
    await vi.advanceTimersByTimeAsync(90_000)
    await result
    expect(signal?.aborted).toBe(true)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect((fetchMock.mock.calls[0][1] as RequestInit).headers).toMatchObject({ 'Idempotency-Key': 'stalled-category' })
  })

  it('includes stalled token acquisition and response parsing in the write deadline', async () => {
    vi.useFakeTimers()
    setAuthTokenGetter(() => new Promise<string>(() => undefined))
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    const authRequest = createBudgetCategory({ name: 'Meals', stack_key: 'discretionary' }, 2026, 'stalled-auth')
    const authResult = expect(authRequest).rejects.toThrow('Refresh to check the current state')
    await vi.advanceTimersByTimeAsync(90_000)
    await authResult
    expect(fetchMock).not.toHaveBeenCalled()

    setAuthTokenGetter(null)
    fetchMock.mockResolvedValue(new Response(new ReadableStream({ start() { /* Stalled body. */ } }), { status: 201 }))
    const bodyRequest = createBudgetCategory({ name: 'Meals', stack_key: 'discretionary' }, 2026, 'stalled-body')
    const bodyResult = expect(bodyRequest).rejects.toThrow('Refresh to check the current state')
    await vi.advanceTimersByTimeAsync(90_000)
    await bodyResult
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
    const firstResult = expect(firstAttempt).rejects.toThrow('Your assistant took too long to finish this request. Refresh to check the current state before trying again.')
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
    const result = expect(request).rejects.toThrow('Your assistant took too long to finish this request. Refresh to check the current state before trying again.')
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
    const result = expect(request).rejects.toThrow('Your assistant took too long to finish this request. Refresh to check the current state before trying again.')
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


describe('voice transcription deadlines', () => {
  it('aborts a stalled transcription and returns a usable recovery message', async () => {
    vi.useFakeTimers()
    let signal: AbortSignal | null | undefined
    vi.stubGlobal('fetch', vi.fn((_input: RequestInfo | URL, init?: RequestInit) => {
      signal = init?.signal
      return new Promise<Response>(() => undefined)
    }))
    const result = expect(transcribeMiaVoice(new Blob(['synthetic audio'], { type: 'audio/webm' }))).rejects.toThrow('Voice transcription took too long. Record again or type your note.')
    await vi.advanceTimersByTimeAsync(180_000)
    await result
    expect(signal?.aborted).toBe(true)
  })
})

describe('feedback submission deadlines', () => {
  const values = {
    workflow: 'ask_mia' as const, attempted: 'Open the chat', expected: 'See a reply', actual: 'The reply did not appear',
  }
  const timeoutMessage = 'The server did not confirm whether your report was received. It may already be submitted. Keep your details and check with support before submitting again.'

  it('bounds stalled authentication without submitting or automatically retrying the report', async () => {
    vi.useFakeTimers()
    setAuthTokenGetter(() => new Promise<string | null>(() => undefined))
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)

    const result = expect(submitPilotFeedback(values)).rejects.toThrow(timeoutMessage)
    await vi.advanceTimersByTimeAsync(180_000)
    await result
    expect(fetchMock).not.toHaveBeenCalled()
    expect(vi.getTimerCount()).toBe(0)
  })

  it('aborts a stalled upload without retrying a possibly received report', async () => {
    vi.useFakeTimers()
    let signal: AbortSignal | null | undefined
    const fetchMock = vi.fn((_input: RequestInfo | URL, init?: RequestInit) => {
      signal = init?.signal
      return new Promise<Response>(() => undefined)
    })
    vi.stubGlobal('fetch', fetchMock)

    const result = expect(submitPilotFeedback({ ...values, screenshot: new File(['image'], 'issue.png', { type: 'image/png' }) })).rejects.toThrow(timeoutMessage)
    await vi.advanceTimersByTimeAsync(179_999)
    expect(signal?.aborted).toBe(false)
    await vi.advanceTimersByTimeAsync(1)
    await result
    expect(signal?.aborted).toBe(true)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
  })

  it.each([201, 422])('bounds stalled response body parsing for HTTP %i', async (status) => {
    vi.useFakeTimers()
    const fetchMock = vi.fn().mockResolvedValue(new Response(new ReadableStream({ start() { /* Stalled response body. */ } }), { status }))
    vi.stubGlobal('fetch', fetchMock)

    const result = expect(submitPilotFeedback(values)).rejects.toThrow(timeoutMessage)
    await vi.advanceTimersByTimeAsync(180_000)
    await result
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect((fetchMock.mock.calls[0][1] as RequestInit).signal?.aborted).toBe(true)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('keeps the multipart upload and receipt contract and clears the deadline on success', async () => {
    vi.useFakeTimers()
    const receipt = { id: 42, screenshot_attached: true }
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({ feedback_report: receipt }), { status: 201 }))
    vi.stubGlobal('fetch', fetchMock)
    const screenshot = new File(['image'], 'issue.png', { type: 'image/png' })

    await expect(submitPilotFeedback({ ...values, screenshot })).resolves.toEqual(receipt)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/v1/pilot_feedback_reports')
    expect(init.method).toBe('POST')
    expect(init.signal?.aborted).toBe(false)
    const body = init.body as FormData
    expect(body.get('feedback_report[attempted]')).toBe(values.attempted)
    expect(body.get('screenshot')).toBe(screenshot)
    expect(vi.getTimerCount()).toBe(0)
  })
})


describe('authenticated financial source content', () => {
  it('derives the app route and refreshes Bearer, brand and workspace headers for each read instead of following metadata URLs', async () => {
    let token = 'first-private-token'
    setAuthTokenGetter(async () => token)
    setActiveCoachWorkspaceId(42)
    const fetchMock = vi.fn().mockResolvedValueOnce(jsonResponse({ authenticated_content: true, url: 'https://evil.example/private.pdf', download_url: 'https://evil.example/download', expires_in: 0, filename: 'fictional.pdf', content_type: 'application/pdf', inline_supported: true })).mockImplementation(async () => new Response(new Blob(['fictional PDF'], { type: 'application/pdf' })))
    vi.stubGlobal('fetch', fetchMock)
    await fetchDocumentImportSourceUrl(606)
    const first = await fetchDocumentImportSourceContent(606)
    expect(first.type).toBe('application/pdf')
    token = 'second-private-token'
    setActiveCoachWorkspaceId(43)
    await fetchDocumentImportSourceContent(606, true)
    expect(String(fetchMock.mock.calls[1][0])).toMatch(/\/api\/v1\/document_imports\/606\/source_content$/)
    expect(String(fetchMock.mock.calls[2][0])).toMatch(/\/api\/v1\/document_imports\/606\/source_content\?download=1$/)
    expect(JSON.stringify(fetchMock.mock.calls)).not.toContain('evil.example')
    expect((fetchMock.mock.calls[1][1] as RequestInit).headers).toMatchObject({ Authorization: 'Bearer first-private-token', 'X-Coach-Workspace-Id': '42', 'X-Brand-Hostname': browserBrandHostname() })
    expect((fetchMock.mock.calls[2][1] as RequestInit).headers).toMatchObject({ Authorization: 'Bearer second-private-token', 'X-Coach-Workspace-Id': '43' })
    expect((fetchMock.mock.calls[2][1] as RequestInit).cache).toBe('no-store')
  })
  it('rejects revoked reads without returning bytes and rejects invalid import identities before any request', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ error: 'Source access revoked.' }, 403))
    vi.stubGlobal('fetch', fetchMock)
    await expect(fetchDocumentImportSourceContent(606)).rejects.toMatchObject({ status: 403, message: 'Source access revoked.' })
    await expect(fetchDocumentImportSourceContent(-1)).rejects.toThrow('valid document import')
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })
  it('keeps consumption of Blob bytes inside the request deadline', async () => {
    vi.useFakeTimers()
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, headers: new Headers(), blob: () => new Promise<Blob>(() => undefined) })
    vi.stubGlobal('fetch', fetchMock)
    const request = fetchDocumentImportSourceContent(606)
    const failure = expect(request).rejects.toThrow('Private document content took too long.')
    await vi.advanceTimersByTimeAsync(60_001)
    await failure
    expect((fetchMock.mock.calls[0][1] as RequestInit).signal?.aborted).toBe(true)
  })
})
