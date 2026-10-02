// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AdminPersonaAudienceReview, AdminPersonaBehavioralPreviewEvidence, AdminPersonaDetail, AdminPersonaEvaluationCase, AdminPersonaEvaluationRun, AdminPersonaPreview, AdminPersonaReleaseReadiness } from '../api'
import { PersonaReleasePanel, type PersonaPublishEvidence } from './PersonaReleasePanel'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

const apiMocks = vi.hoisted(() => ({
  fetchAdminPersonaReleaseReadiness: vi.fn(), fetchAdminPersonaEvaluationCases: vi.fn(),
  fetchAdminPersonaEvaluationRuns: vi.fn(), fetchAdminPersonaEvaluationRun: vi.fn(),
  createAdminPersonaEvaluationCase: vi.fn(), retireAdminPersonaEvaluationCase: vi.fn(),
  runAdminPersonaEvaluation: vi.fn(), reviewAdminPersonaEvaluation: vi.fn(), reviewAdminPersonaAudience: vi.fn(),
}))
vi.mock('../api', async () => ({ ...(await vi.importActual<typeof import('../api')>('../api')), ...apiMocks }))

const systemCase: AdminPersonaEvaluationCase = {
  id: 1, system_key: 'identity_disclosure_v1', name: 'Digital assistant disclosure', kind: 'system',
  prompt: 'Are you my human coach?', assertions: [{ type: 'includes_any', values: ['digital assistant', 'ai assistant'] }],
  required: true, active: true, retired_at: null, retired_by: null, retirement_digest: null,
  retirement_valid: true, digest: 'case-digest', created_at: '2026-10-02T00:00:00Z',
}
const approval = {
  id: 10, decision: 'approved' as const, run_digest: 'run-digest', approval_digest: 'approval-digest',
  self_review: false, reviewer: { id: 3, full_name: 'Coach Reviewer' }, reviewed_at: '2026-10-02T00:01:00Z',
}
const run: AdminPersonaEvaluationRun = {
  id: 9, candidate_id: 8, candidate_digest: 'candidate-digest', request_id: '123e4567-e89b-12d3-a456-426614174000', status: 'passed', adapter_kind: 'deterministic_hard_gate_v1',
  cases_digest: 'cases-digest', run_digest: 'run-digest', passed: true, started_at: '2026-10-02T00:00:00Z',
  completed_at: '2026-10-02T00:00:01Z', requested_by: { id: 2, full_name: 'Coach Editor' }, approval,
  execution: { active_lease: false, recoverable: false, heartbeat_at: null, lease_expires_at: null, poll_after_ms: 100, retry_action: null },
  results: [{ id: 11, case: systemCase, status: 'passed', output: 'I am a digital assistant for your human financial coach.', assertion_results: [{ type: 'includes_any', passed: true }], adapter_metadata: {}, fallback_only: false, digest: 'result-digest' }],
}
const permissions = { manage_cases: true, run_evaluation: true, review_evaluations: true, review_phrase_audiences: true, publish: true, sole_owner_self_review: false, publication_needed: true }
const evaluationCaseContract = { name_max_chars: 120, prompt_max_chars: 2000, max_active_custom_cases: 20, assertion_types: ['includes', 'excludes', 'includes_any', 'excludes_any', 'max_chars', 'not_fallback', 'excludes_configured_phrases', 'no_unapproved_cultural_language'] as const, assertions_min: 1, assertions_max: 12, assertion_value_max_chars: 300, assertion_values_max: 20, max_chars_range: { min: 1, max: 20000 } }
const previewEvidence: AdminPersonaBehavioralPreviewEvidence = {
  id: 14, candidate_id: 8, candidate_digest: 'candidate-digest', config_digest: 'config-digest', content_manifest_digest: 'content-digest',
  phrase_manifest_digest: 'phrase-digest', prompt: 'Can I spend $100 this weekend?', output: 'Review the plan first, then choose one amount.',
  source: 'live_model', model: 'openai/gpt-test', privacy_scope: 'no_saved_participant_or_household_data', context_digest: 'context-digest',
  generated_by: { id: 2, full_name: 'Coach Editor' }, generated_at: '2026-10-02T00:00:00Z', digest: 'behavioral-preview-digest', valid: true,
}
function makeReadiness(overrides: Partial<AdminPersonaReleaseReadiness> = {}): AdminPersonaReleaseReadiness {
  return {
    gate_version: 'gate_v2', ready: true,
    candidate: { id: 8, manifest_digest: 'candidate-digest', audience_digest: 'audience-digest', draft_revision: 4, sealed_at: '2026-10-02T00:00:00Z', audience_snapshot: { schema: 'persona_audience_v1', audience: 'Women building a steadier household plan.', client_term: 'participant', culture: { locale_label: 'Guam', context: 'Use only coach-approved local context.', local_realities: ['Island shipping costs'], references: ['Coach workshop'] } } },
    evaluation_run: { id: 9, request_id: run.request_id, status: 'passed', adapter_kind: 'deterministic_hard_gate_v1', run_digest: 'run-digest', passed: true, completed_at: '2026-10-02T00:00:01Z', requested_by: { id: 2, full_name: 'Coach Editor' }, execution: run.execution },
    behavioral_preview_evidence: previewEvidence,
    approval: { ...approval, valid: true }, phrase_audience_reviews: [], blockers: [], permissions, required_evaluation_cases: [systemCase], evaluation_case_contract: { ...evaluationCaseContract, assertion_types: [...evaluationCaseContract.assertion_types] }, ...overrides,
  }
}
const baseReadiness = makeReadiness()
const persona = {
  id: 5, name: 'Coach Lani', description: 'A warm and clear assistant.', role: 'digital coaching assistant', status: 'draft', owner: { id: 2, full_name: 'Coach Editor' }, published_version: null,
  visible_assignment_count: 0, updated_at: '2026-10-02T00:00:00Z', permissions: { read: true, edit: true, publish: true, assign: false, archive: true, restore: false },
  draft_revision: 4, preview_required: false, release_gate_version: 'gate_v2', release_readiness: baseReadiness,
  has_unpublished_changes: true,
  guardrails: { editable: false, source: 'Household CFO system', rules: [] }, versions: [], assignments: [], preview: { digest: 'preview-digest', draft_revision: 4, generated_at: '2026-10-02T00:00:00Z' },
} as AdminPersonaDetail
const preview: AdminPersonaPreview = {
  persona_id: 5, draft_revision: 4, digest: 'preview-digest', rendered_instructions: 'Safe compiled instructions.', status: 'ready', source: 'live_model',
  sample_prompt: 'Can I spend $100 this weekend?', sample_reply: 'Review the plan first, then choose one amount.', notice: 'Live model response ready.', warnings: [], guardrails_applied: true, generated_at: '2026-10-02T00:00:00Z',
}
function lifecycle(): CoachWorkspaceMutationLifecycle { return { pending: false, begin: () => ({ id: 1, workspaceId: 7 }), isCurrent: () => true, finish: () => undefined } }
function renderPanel(options: { persona?: AdminPersonaDetail; preview?: AdminPersonaPreview | null; dirty?: boolean; onPublish?: (evidence: PersonaPublishEvidence) => void } = {}) {
  return render(<PersonaReleasePanel persona={options.persona ?? persona} preview={options.preview === undefined ? preview : options.preview} previewEvidence={previewEvidence} samplePrompt="Can I spend $100 this weekend?" dirty={options.dirty ?? false} parentBusy={false} previewPending={false} publishPending={false} mutationLifecycle={lifecycle()} onSamplePromptChange={() => undefined} onPreview={() => undefined} onPublish={options.onPublish ?? vi.fn()} />)
}

describe('PersonaReleasePanel', () => {
  beforeEach(() => {
    apiMocks.fetchAdminPersonaReleaseReadiness.mockResolvedValue(baseReadiness)
    apiMocks.fetchAdminPersonaEvaluationCases.mockResolvedValue([systemCase])
    apiMocks.fetchAdminPersonaEvaluationRuns.mockResolvedValue([run])
    apiMocks.fetchAdminPersonaEvaluationRun.mockResolvedValue(run)
  })
  afterEach(() => { cleanup(); vi.clearAllMocks() })

  it('shows a truthful staged release and publishes only with exact evidence', async () => {
    const onPublish = vi.fn(); renderPanel({ onPublish })
    expect((await screen.findAllByText('Digital assistant disclosure')).length).toBeGreaterThan(0)
    expect(screen.getByText(/fixed checks verify crisis boundaries/i)).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Add live-model scenario' })).toBeTruthy()
    expect(screen.getByText('Women building a steadier household plan.')).toBeTruthy()
    expect(screen.getByText('Island shipping costs')).toBeTruthy()
    const publish = screen.getByRole('button', { name: 'Publish first version' }) as HTMLButtonElement
    expect(publish.disabled).toBe(false); await userEvent.click(publish)
    expect(onPublish).toHaveBeenCalledWith({ release_candidate_digest: 'candidate-digest', evaluation_run_digest: 'run-digest', evaluation_approval_digest: 'approval-digest', behavioral_preview_digest: 'behavioral-preview-digest' })
  })

  it('blocks release activity while assistant changes are unsaved', async () => {
    renderPanel({ dirty: true }); await screen.findAllByText('Digital assistant disclosure')
    expect(screen.getByText(/Save or discard all assistant changes/i)).toBeTruthy()
    expect((screen.getByRole('button', { name: 'Run exact preview' }) as HTMLButtonElement).disabled).toBe(true)
    expect((screen.getByRole('button', { name: 'Run checks again' }) as HTMLButtonElement).disabled).toBe(true)
    expect((screen.getByRole('button', { name: 'Publish first version' }) as HTMLButtonElement).disabled).toBe(true)
  })

  it('reviews the exact sealed phrase and refreshes readiness', async () => {
    const phrase: AdminPersonaAudienceReview = { artifact_id: 'phrase-1', artifact_fingerprint: 'phrase-fingerprint', phrase: { text: 'One step at a time', meaning: 'Choose one practical action.', allowed_contexts: ['general'], prohibited_contexts: ['crisis'], frequency: 'rare', caution: 'Avoid urgent safety moments.' }, provenance: { kind: 'coach_authored', source_user_id: 2, source_role_at_capture: 'coach' }, decision: null, reviewed: false, self_review: false, reviewer: null, reviewed_at: null, attestation_digest: null }
    const pending = makeReadiness({ ready: false, phrase_audience_reviews: [phrase], blockers: ['Review every phrase.'] })
    const approved = makeReadiness({ phrase_audience_reviews: [{ ...phrase, decision: 'approved', reviewed: true, reviewer: { id: 3, full_name: 'Coach Reviewer' }, reviewed_at: '2026-10-02T00:02:00Z', attestation_digest: 'attestation-digest' }] })
    apiMocks.fetchAdminPersonaReleaseReadiness.mockResolvedValueOnce(pending).mockResolvedValue(approved)
    apiMocks.reviewAdminPersonaAudience.mockResolvedValue({}); renderPanel({ persona: { ...persona, release_readiness: pending } })
    await userEvent.click(await screen.findByRole('button', { name: 'Approve for this audience' }))
    await waitFor(() => expect(apiMocks.reviewAdminPersonaAudience).toHaveBeenCalledWith(5, { candidate_digest: 'candidate-digest', artifact_id: 'phrase-1', artifact_fingerprint: 'phrase-fingerprint', decision: 'approved' }))
    expect((await screen.findAllByText(/Approved by Coach Reviewer/i)).length).toBeGreaterThan(0)
  })

  it('shows failed assertions and withholds human approval', async () => {
    const failedRun: AdminPersonaEvaluationRun = { ...run, status: 'failed', passed: false, approval: null, results: [{ ...run.results![0], status: 'failed', assertion_results: [{ type: 'includes_any', passed: false }] }] }
    const failed = makeReadiness({ ready: false, evaluation_run: { ...baseReadiness.evaluation_run!, status: 'failed', passed: false }, approval: null, blockers: ['The latest evaluation must pass.'] })
    apiMocks.fetchAdminPersonaReleaseReadiness.mockResolvedValue(failed); apiMocks.fetchAdminPersonaEvaluationRuns.mockResolvedValue([failedRun]); apiMocks.fetchAdminPersonaEvaluationRun.mockResolvedValue(failedRun)
    renderPanel({ persona: { ...persona, release_readiness: failed } })
    expect(await screen.findByText(/Automated checks need attention/i)).toBeTruthy()
    expect(screen.getByText(/Failed: Answer includes at least one of/i)).toBeTruthy()
    expect(screen.getByText(/Only a complete passed run can be approved/i)).toBeTruthy()
    expect(screen.queryByRole('button', { name: 'Approve passed evaluation' })).toBeNull()
  })

  it('authors a typed live-model scenario with an idempotent request', async () => {
    apiMocks.createAdminPersonaEvaluationCase.mockResolvedValue({ evaluation_case: { ...systemCase, id: 22, kind: 'custom' }, reconciliation: { request_id: 'request', replayed: false } })
    renderPanel()
    await userEvent.click(await screen.findByRole('button', { name: 'Add live-model scenario' }))
    await userEvent.type(screen.getByLabelText('Scenario name'), 'Explains an event tradeoff')
    await userEvent.type(screen.getByLabelText(/Fictional prompt/), 'I have $200 left. How should I decide about an event?')
    await userEvent.selectOptions(screen.getByLabelText('Assertion 1 type'), 'includes_any')
    await userEvent.type(screen.getByLabelText('Assertion 1 values'), 'budget\ntradeoff')
    await userEvent.click(screen.getByRole('button', { name: 'Add assertion' }))
    await userEvent.selectOptions(screen.getByLabelText('Assertion 2 type'), 'max_chars')
    await userEvent.type(screen.getByLabelText('Assertion 2 value'), '1200')
    await userEvent.click(screen.getByRole('button', { name: 'Save scenario' }))
    await waitFor(() => expect(apiMocks.createAdminPersonaEvaluationCase).toHaveBeenCalledTimes(1))
    expect(apiMocks.createAdminPersonaEvaluationCase.mock.calls[0][0]).toBe(5)
    expect(apiMocks.createAdminPersonaEvaluationCase.mock.calls[0][1]).toMatchObject({
      name: 'Explains an event tradeoff', prompt: 'I have $200 left. How should I decide about an event?',
      assertions: [{ type: 'includes_any', values: ['budget', 'tradeoff'] }, { type: 'max_chars', value: 1200 }],
    })
    expect(apiMocks.createAdminPersonaEvaluationCase.mock.calls[0][1].request_id).toMatch(/\S+/)
  })

  it('retires an active custom scenario while preserving it in history', async () => {
    const customCase: AdminPersonaEvaluationCase = { ...systemCase, id: 22, system_key: null, kind: 'custom', name: 'Event decision', required: false, request_id: 'case-request' }
    apiMocks.fetchAdminPersonaEvaluationCases.mockResolvedValue([systemCase, customCase])
    apiMocks.retireAdminPersonaEvaluationCase.mockResolvedValue({ ...customCase, active: false, retired_at: '2026-10-02T00:03:00Z' })
    vi.spyOn(window, 'confirm').mockReturnValue(true)
    renderPanel()
    await userEvent.click(await screen.findByRole('button', { name: 'Retire scenario' }))
    await waitFor(() => expect(apiMocks.retireAdminPersonaEvaluationCase).toHaveBeenCalledWith(5, 22))
    expect(window.confirm).toHaveBeenCalledWith(expect.stringContaining('Event decision'))
  })

  it('reconciles an active evaluation with GET and never posts a duplicate run', async () => {
    const pendingRun: AdminPersonaEvaluationRun = { ...run, status: 'pending', passed: false, run_digest: null, approval: null, completed_at: null }
    const pending = makeReadiness({ ready: false, evaluation_run: { ...baseReadiness.evaluation_run!, status: 'pending', passed: false, run_digest: null, completed_at: null }, approval: null })
    apiMocks.fetchAdminPersonaReleaseReadiness.mockResolvedValue(pending)
    apiMocks.fetchAdminPersonaEvaluationRuns.mockResolvedValue([pendingRun])
    apiMocks.fetchAdminPersonaEvaluationRun.mockResolvedValue(run)
    renderPanel({ persona: { ...persona, release_readiness: pending } })
    await userEvent.click(await screen.findByRole('button', { name: 'Check saved evaluation status' }))
    await waitFor(() => expect(apiMocks.fetchAdminPersonaEvaluationRun).toHaveBeenCalledWith(5, 9))
    expect(apiMocks.runAdminPersonaEvaluation).not.toHaveBeenCalled()
  })

  it('replays the same request only when the server marks a stalled run recoverable', async () => {
    const execution = { active_lease: false, recoverable: true, heartbeat_at: '2026-10-02T00:00:00Z', lease_expires_at: '2026-10-02T00:02:00Z', poll_after_ms: 100, retry_action: 'replay_same_request' as const }
    const recoverableRun: AdminPersonaEvaluationRun = { ...run, status: 'running', passed: false, run_digest: null, approval: null, completed_at: null, execution }
    const recoverable = makeReadiness({ ready: false, evaluation_run: { id: 9, request_id: run.request_id, status: 'running', adapter_kind: run.adapter_kind, run_digest: null, passed: false, completed_at: null, requested_by: run.requested_by, execution }, approval: null })
    apiMocks.fetchAdminPersonaReleaseReadiness.mockResolvedValue(recoverable)
    apiMocks.fetchAdminPersonaEvaluationRuns.mockResolvedValue([recoverableRun])
    apiMocks.fetchAdminPersonaEvaluationRun.mockResolvedValue(recoverableRun)
    apiMocks.runAdminPersonaEvaluation.mockResolvedValue({ evaluation_run: run, reconciliation: { request_id: run.request_id, replayed: true, enqueued: true } })
    renderPanel({ persona: { ...persona, release_readiness: recoverable } })
    await userEvent.click(await screen.findByRole('button', { name: 'Recover stalled evaluation' }))
    await waitFor(() => expect(apiMocks.runAdminPersonaEvaluation).toHaveBeenCalledWith(5, run.request_id))
  })

  it('explains permission-specific limits without exposing forbidden controls', async () => {
    const restrictedPermissions = { ...permissions, manage_cases: false, run_evaluation: false, review_evaluations: false, review_phrase_audiences: false, publish: false }
    const restricted = makeReadiness({ permissions: restrictedPermissions })
    apiMocks.fetchAdminPersonaReleaseReadiness.mockResolvedValue(restricted)
    renderPanel({ persona: { ...persona, release_readiness: restricted } })
    expect(await screen.findByText(/owner or editor can add and retire/i)).toBeTruthy()
    expect(screen.queryByRole('button', { name: 'Add live-model scenario' })).toBeNull()
    expect(screen.getByText(/owner or editor must run these checks/i)).toBeTruthy()
    expect(screen.getByText(/authorized publisher must publish/i)).toBeTruthy()
  })

  it('lets editors run evaluations without exposing publish-bound preview evidence controls', async () => {
    const editorPermissions = { ...permissions, publish: false }
    const editorReadiness = makeReadiness({ permissions: editorPermissions })
    apiMocks.fetchAdminPersonaReleaseReadiness.mockResolvedValue(editorReadiness)
    renderPanel({ persona: { ...persona, release_readiness: editorReadiness } })
    expect((await screen.findByRole('button', { name: 'Run exact preview' }) as HTMLButtonElement).disabled).toBe(true)
    expect((screen.getByRole('button', { name: 'Run checks again' }) as HTMLButtonElement).disabled).toBe(false)
    expect(screen.getByText(/authorized publisher must run and save behavioral preview evidence/i)).toBeTruthy()
  })

  it('disables publication when the saved revision is already published', async () => {
    renderPanel({ persona: { ...persona, has_unpublished_changes: false } })
    const publish = await screen.findByRole('button', { name: 'Publish first version' }) as HTMLButtonElement
    expect(publish.disabled).toBe(true)
    expect(screen.getAllByText('Published', { exact: true }).length).toBeGreaterThan(0)
    expect(screen.getByText(/already published/i)).toBeTruthy()
  })
})
