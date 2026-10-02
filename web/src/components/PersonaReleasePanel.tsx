import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  ApiRequestError,
  createAdminPersonaEvaluationCase,
  fetchAdminPersonaEvaluationCases,
  fetchAdminPersonaEvaluationRun,
  fetchAdminPersonaEvaluationRuns,
  fetchAdminPersonaReleaseReadiness,
  reviewAdminPersonaAudience,
  reviewAdminPersonaEvaluation,
  retireAdminPersonaEvaluationCase,
  runAdminPersonaEvaluation,
} from '../api'
import type {
  AdminPersonaAudienceReview,
  AdminPersonaBehavioralPreviewEvidence,
  AdminPersonaDetail,
  AdminPersonaEvaluationAssertion,
  AdminPersonaEvaluationCase,
  AdminPersonaEvaluationCaseContract,
  AdminPersonaEvaluationRun,
  AdminPersonaPreview,
  AdminPersonaReleaseReadiness,
} from '../api'
import { Button } from './Button'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

const TERMINAL_RUN_STATUSES = new Set(['passed', 'failed', 'error'])
const RUN_POLL_INTERVAL_MS = 1_750
const RUN_POLL_LIMIT = 60
const ASSERTION_OPTIONS: Array<{ value: AdminPersonaEvaluationAssertion['type']; label: string }> = [
  { value: 'includes', label: 'Includes exact text' },
  { value: 'excludes', label: 'Excludes exact text' },
  { value: 'includes_any', label: 'Includes at least one choice' },
  { value: 'excludes_any', label: 'Excludes every listed choice' },
  { value: 'max_chars', label: 'Stays within a character limit' },
  { value: 'not_fallback', label: 'Uses a real model answer' },
  { value: 'excludes_configured_phrases', label: 'Uses no configured community phrase' },
  { value: 'no_unapproved_cultural_language', label: 'Uses no unapproved cultural language' },
]
const DEFAULT_CASE_CONTRACT: AdminPersonaEvaluationCaseContract = {
  name_max_chars: 120,
  prompt_max_chars: 2_000,
  max_active_custom_cases: 20,
  assertion_types: ASSERTION_OPTIONS.map((option) => option.value),
  assertions_min: 1,
  assertions_max: 12,
  assertion_value_max_chars: 300,
  assertion_values_max: 20,
  max_chars_range: { min: 1, max: 20_000 },
}

type ReleaseAction = 'run' | 'create_case' | `retire_case:${number}` | 'approve' | 'reject_run' | `phrase:${string}:approved` | `phrase:${string}:rejected` | null

type AssertionDraft = {
  id: string
  type: AdminPersonaEvaluationAssertion['type']
  value: string
}

export type PersonaPublishEvidence = {
  release_candidate_digest: string
  evaluation_run_digest: string
  evaluation_approval_digest: string
  behavioral_preview_digest: string
}

type PersonaReleasePanelProps = {
  persona: AdminPersonaDetail
  preview: AdminPersonaPreview | null
  previewEvidence: AdminPersonaBehavioralPreviewEvidence | null
  samplePrompt: string
  dirty: boolean
  parentBusy: boolean
  previewPending: boolean
  publishPending: boolean
  mutationLifecycle: CoachWorkspaceMutationLifecycle
  onSamplePromptChange: (value: string) => void
  onPreview: () => void
  onPublish: (evidence: PersonaPublishEvidence) => void
}

export function PersonaReleasePanel({
  persona,
  preview,
  previewEvidence,
  samplePrompt,
  dirty,
  parentBusy,
  previewPending,
  publishPending,
  mutationLifecycle,
  onSamplePromptChange,
  onPreview,
  onPublish,
}: PersonaReleasePanelProps) {
  const [readiness, setReadiness] = useState<AdminPersonaReleaseReadiness | null>(persona.release_readiness ?? null)
  const [cases, setCases] = useState<AdminPersonaEvaluationCase[]>([])
  const [runs, setRuns] = useState<AdminPersonaEvaluationRun[]>([])
  const [selectedRun, setSelectedRun] = useState<AdminPersonaEvaluationRun | null>(null)
  const [loading, setLoading] = useState(true)
  const [action, setAction] = useState<ReleaseAction>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [runRequestId, setRunRequestId] = useState<string | null>(null)
  const [caseRequestId, setCaseRequestId] = useState<string | null>(null)
  const [caseFormOpen, setCaseFormOpen] = useState(false)
  const [caseName, setCaseName] = useState('')
  const [casePrompt, setCasePrompt] = useState('')
  const [assertionDrafts, setAssertionDrafts] = useState<AssertionDraft[]>([newAssertionDraft('not_fallback')])
  const [previewEvidenceOverride, setPreviewEvidenceOverride] = useState<{
    sourceDigest: string | null
    evidence: AdminPersonaBehavioralPreviewEvidence
  } | null>(null)
  const requestSequence = useRef(0)
  const personaIdRef = useRef(persona.id)
  const mountedRef = useRef(false)

  const loadReleaseState = useCallback(async (options: { quiet?: boolean; preferredRunId?: number | null } = {}) => {
    const sequence = ++requestSequence.current
    const personaId = persona.id
    if (!options.quiet) setLoading(true)
    setError(null)
    try {
      const [nextReadiness, nextCases, nextRuns] = await Promise.all([
        fetchAdminPersonaReleaseReadiness(personaId),
        fetchAdminPersonaEvaluationCases(personaId),
        fetchAdminPersonaEvaluationRuns(personaId),
      ])
      if (sequence !== requestSequence.current || personaIdRef.current !== personaId) return null
      setReadiness(nextReadiness)
      if (nextReadiness.evaluation_run && TERMINAL_RUN_STATUSES.has(nextReadiness.evaluation_run.status)) setRunRequestId(null)
      setCases(nextCases)
      setRuns(nextRuns)
      const preferredId = options.preferredRunId ?? nextReadiness.evaluation_run?.id ?? nextRuns[0]?.id ?? null
      const summary = nextRuns.find((run) => run.id === preferredId) ?? null
      if (!preferredId) {
        setSelectedRun(null)
        return { readiness: nextReadiness, runs: nextRuns, selectedRun: null }
      }
      try {
        const detail = await fetchAdminPersonaEvaluationRun(personaId, preferredId)
        if (sequence !== requestSequence.current || personaIdRef.current !== personaId) return null
        setSelectedRun(detail)
        return { readiness: nextReadiness, runs: nextRuns, selectedRun: detail }
      } catch (caught) {
        if (sequence !== requestSequence.current || personaIdRef.current !== personaId) return null
        setSelectedRun(summary)
        setError(errorMessage(caught, 'The latest check details could not be loaded. Refresh release checks to try again.'))
        return { readiness: nextReadiness, runs: nextRuns, selectedRun: summary }
      }
    } catch (caught) {
      if (sequence === requestSequence.current && personaIdRef.current === personaId) {
        setError(errorMessage(caught, 'Release checks could not be loaded.'))
      }
      return null
    } finally {
      if (sequence === requestSequence.current && personaIdRef.current === personaId && !options.quiet) setLoading(false)
    }
  }, [persona.id])

  useEffect(() => {
    mountedRef.current = true
    personaIdRef.current = persona.id
    queueMicrotask(() => void loadReleaseState())
    return () => {
      mountedRef.current = false
      requestSequence.current += 1
    }
  }, [loadReleaseState, persona.id])

  const pollRun = useCallback(async (runId: number, pollAfterMs = RUN_POLL_INTERVAL_MS) => {
    const personaId = persona.id
    const interval = Math.max(500, Math.min(10_000, pollAfterMs))
    for (let attempt = 0; attempt < RUN_POLL_LIMIT; attempt += 1) {
      await delay(interval)
      if (!mountedRef.current || personaIdRef.current !== personaId) return null
      try {
        const next = await fetchAdminPersonaEvaluationRun(personaId, runId)
        if (!mountedRef.current || personaIdRef.current !== personaId) return null
        setSelectedRun(next)
        setRuns((current) => replaceRun(current, next))
        if (TERMINAL_RUN_STATUSES.has(next.status) || next.execution.recoverable) return next
      } catch (caught) {
        if (caught instanceof ApiRequestError && caught.status === 404) return null
      }
    }
    return null
  }, [persona.id])

  async function runChecks() {
    if (!readiness?.permissions.run_evaluation || dirty || action || parentBusy) return
    const activeRun = selectedRun && selectedRun.id === readiness.evaluation_run?.id && !TERMINAL_RUN_STATUSES.has(selectedRun.status) ? selectedRun : null
    if (readiness.evaluation_run && !TERMINAL_RUN_STATUSES.has(readiness.evaluation_run.status) && !activeRun?.execution.recoverable) {
      await reconcileActiveRun(readiness.evaluation_run.id)
      return
    }
    const ticket = mutationLifecycle.begin()
    const recovering = activeRun?.execution.recoverable === true && activeRun.execution.retry_action === 'replay_same_request'
    const requestId = recovering ? activeRun.request_id : runRequestId ?? newRequestId()
    setRunRequestId(requestId)
    setAction('run')
    setError(null)
    setNotice(null)
    try {
      const response = await runAdminPersonaEvaluation(persona.id, requestId)
      if (!mutationLifecycle.isCurrent(ticket) || personaIdRef.current !== persona.id) return
      const initialRun = response.evaluation_run
      setSelectedRun(initialRun)
      setRuns((current) => replaceRun(current, initialRun))
      const nextRun = TERMINAL_RUN_STATUSES.has(initialRun.status) ? initialRun : await pollRun(initialRun.id, initialRun.execution.poll_after_ms ?? RUN_POLL_INTERVAL_MS) ?? initialRun
      if (!mutationLifecycle.isCurrent(ticket) || personaIdRef.current !== persona.id) return
      const terminal = TERMINAL_RUN_STATUSES.has(nextRun.status)
      if (terminal) setRunRequestId(null)
      await loadReleaseState({ quiet: true, preferredRunId: nextRun.id })
      if (!mutationLifecycle.isCurrent(ticket)) return
      setNotice(nextRun.execution.recoverable
        ? 'The recovered evaluation stopped before it finished. Its saved request is ready for another safe recovery attempt.'
        : !terminal
        ? 'The release checks are still running. Refresh this page or check the run again; its saved request will resume without creating a duplicate.'
        : recovering && nextRun.status === 'passed'
          ? 'The stalled evaluation was safely recovered and all checks passed.'
        : nextRun.status === 'passed'
        ? 'All configured release checks passed for this exact saved draft.'
        : nextRun.status === 'failed'
          ? 'One or more release checks failed. Review the results before running them again.'
          : 'The release checks could not finish. Review the result and try again.')
    } catch (caught) {
      if (!mutationLifecycle.isCurrent(ticket) || personaIdRef.current !== persona.id) return
      const reconciled = await loadReleaseState({ quiet: true })
      if (!mutationLifecycle.isCurrent(ticket)) return
      const latest = reconciled?.runs[0]
      if (latest && latest.id !== runs[0]?.id) {
        setSelectedRun(reconciled?.selectedRun ?? latest)
        setNotice('The request may have completed while the connection was interrupted. The latest check result is loaded below.')
      } else {
        setError(`${errorMessage(caught, 'The release checks could not run.')} Refresh the release checks or retry; the same request will not create a duplicate.`)
      }
    } finally {
      if (mutationLifecycle.isCurrent(ticket)) setAction(null)
      mutationLifecycle.finish(ticket)
    }
  }

  async function reconcileActiveRun(runId: number) {
    setAction('run')
    setError(null)
    setNotice(null)
    try {
      const initialRun = await fetchAdminPersonaEvaluationRun(persona.id, runId)
      if (!mountedRef.current || personaIdRef.current !== persona.id) return
      setSelectedRun(initialRun)
      setRuns((current) => replaceRun(current, initialRun))
      const nextRun = TERMINAL_RUN_STATUSES.has(initialRun.status) ? initialRun : await pollRun(initialRun.id, initialRun.execution.poll_after_ms ?? RUN_POLL_INTERVAL_MS) ?? initialRun
      if (!mountedRef.current || personaIdRef.current !== persona.id) return
      if (TERMINAL_RUN_STATUSES.has(nextRun.status)) setRunRequestId(null)
      await loadReleaseState({ quiet: true, preferredRunId: nextRun.id })
      setNotice(nextRun.execution.recoverable
        ? 'The saved evaluation lease expired before completion. Recover this same request when you are ready; no duplicate run will be created.'
        : TERMINAL_RUN_STATUSES.has(nextRun.status)
        ? 'The saved evaluation status is up to date.'
        : 'The evaluation is still active on the server. You can leave this page and check it again later.')
    } catch (caught) {
      if (!mountedRef.current || personaIdRef.current !== persona.id) return
      await loadReleaseState({ quiet: true, preferredRunId: runId })
      setError(errorMessage(caught, 'The active evaluation status could not be refreshed.'))
    } finally {
      if (mountedRef.current && personaIdRef.current === persona.id) setAction(null)
    }
  }

  async function createCase() {
    if (!readiness?.permissions.manage_cases || dirty || action || parentBusy) return
    const validation = validateCaseDraft(caseName, casePrompt, assertionDrafts, readiness.evaluation_case_contract)
    if (validation.error) {
      setError(validation.error)
      return
    }
    const ticket = mutationLifecycle.begin()
    const requestId = caseRequestId ?? newRequestId()
    setCaseRequestId(requestId)
    setAction('create_case')
    setError(null)
    setNotice(null)
    try {
      await createAdminPersonaEvaluationCase(persona.id, {
        request_id: requestId,
        name: caseName.trim(),
        prompt: casePrompt.trim(),
        assertions: validation.assertions,
      })
      if (!mutationLifecycle.isCurrent(ticket)) return
      setCaseRequestId(null)
      setCaseName('')
      setCasePrompt('')
      setAssertionDrafts([newAssertionDraft('not_fallback')])
      setCaseFormOpen(false)
      await loadReleaseState({ quiet: true })
      if (mutationLifecycle.isCurrent(ticket)) setNotice('The live-model scenario was added. Run fresh checks before publishing.')
    } catch (caught) {
      if (!mutationLifecycle.isCurrent(ticket)) return
      await loadReleaseState({ quiet: true })
      if (mutationLifecycle.isCurrent(ticket)) setError(`${errorMessage(caught, 'The live-model scenario could not be saved.')} Retry keeps the same request and will not create a duplicate.`)
    } finally {
      if (mutationLifecycle.isCurrent(ticket)) setAction(null)
      mutationLifecycle.finish(ticket)
    }
  }

  async function retireCase(evaluationCase: AdminPersonaEvaluationCase) {
    if (!evaluationCase.id || !evaluationCase.active || !readiness?.permissions.manage_cases || dirty || action || parentBusy) return
    if (!window.confirm(`Retire “${evaluationCase.name}”? It stays in the audit history and will not run again.`)) return
    const ticket = mutationLifecycle.begin()
    setAction(`retire_case:${evaluationCase.id}`)
    setError(null)
    setNotice(null)
    try {
      await retireAdminPersonaEvaluationCase(persona.id, evaluationCase.id)
      if (!mutationLifecycle.isCurrent(ticket)) return
      await loadReleaseState({ quiet: true })
      if (mutationLifecycle.isCurrent(ticket)) setNotice('The scenario was retired and remains available in the audit history.')
    } catch (caught) {
      if (!mutationLifecycle.isCurrent(ticket)) return
      await loadReleaseState({ quiet: true })
      if (mutationLifecycle.isCurrent(ticket)) setError(errorMessage(caught, 'The scenario could not be retired.'))
    } finally {
      if (mutationLifecycle.isCurrent(ticket)) setAction(null)
      mutationLifecycle.finish(ticket)
    }
  }

  async function reviewRun(decision: 'approved' | 'rejected') {
    if (!selectedRun?.run_digest || selectedRun.id !== readiness?.evaluation_run?.id || selectedRun.approval || !readiness.permissions.review_evaluations || action || parentBusy) return
    const ticket = mutationLifecycle.begin()
    setAction(decision === 'approved' ? 'approve' : 'reject_run')
    setError(null)
    setNotice(null)
    try {
      await reviewAdminPersonaEvaluation(persona.id, selectedRun.id, decision, selectedRun.run_digest)
      if (!mutationLifecycle.isCurrent(ticket)) return
      await loadReleaseState({ quiet: true, preferredRunId: selectedRun.id })
      if (!mutationLifecycle.isCurrent(ticket)) return
      setNotice(decision === 'approved'
        ? 'The exact passed evaluation is approved.'
        : 'The evaluation was rejected. Run a new evaluation after the draft or checks are corrected.')
    } catch (caught) {
      if (!mutationLifecycle.isCurrent(ticket)) return
      await loadReleaseState({ quiet: true, preferredRunId: selectedRun.id })
      if (mutationLifecycle.isCurrent(ticket)) setError(errorMessage(caught, 'The evaluation review could not be saved. The latest server state is shown.'))
    } finally {
      if (mutationLifecycle.isCurrent(ticket)) setAction(null)
      mutationLifecycle.finish(ticket)
    }
  }

  async function reviewPhrase(artifactId: string, decision: 'approved' | 'rejected') {
    const candidate = readiness?.candidate
    const review = readiness?.phrase_audience_reviews.find((item) => item.artifact_id === artifactId)
    if (!candidate || !review || (review.reviewed && review.review_state === 'approved') || !readiness.permissions.review_phrase_audiences || action || parentBusy) return
    const ticket = mutationLifecycle.begin()
    setAction(`phrase:${artifactId}:${decision}`)
    setError(null)
    setNotice(null)
    try {
      await reviewAdminPersonaAudience(persona.id, {
        candidate_digest: candidate.manifest_digest,
        artifact_id: review.artifact_id,
        artifact_fingerprint: review.artifact_fingerprint,
        decision,
      })
      if (!mutationLifecycle.isCurrent(ticket)) return
      await loadReleaseState({ quiet: true, preferredRunId: selectedRun?.id })
      if (!mutationLifecycle.isCurrent(ticket)) return
      setNotice(decision === 'approved'
        ? 'The phrase is approved for this exact audience and community context.'
        : 'The phrase was rejected for this audience. Remove or replace it in the assistant draft, then run fresh checks.')
    } catch (caught) {
      if (!mutationLifecycle.isCurrent(ticket)) return
      await loadReleaseState({ quiet: true, preferredRunId: selectedRun?.id })
      if (mutationLifecycle.isCurrent(ticket)) setError(errorMessage(caught, 'The phrase audience review could not be saved. The latest server state is shown.'))
    } finally {
      if (mutationLifecycle.isCurrent(ticket)) setAction(null)
      mutationLifecycle.finish(ticket)
    }
  }

  async function selectRun(runId: number) {
    setError(null)
    try {
      const detail = await fetchAdminPersonaEvaluationRun(persona.id, runId)
      if (personaIdRef.current === persona.id) setSelectedRun(detail)
    } catch (caught) {
      if (personaIdRef.current === persona.id) setError(errorMessage(caught, 'The selected check result could not be loaded.'))
    }
  }

  const latestPreviewEvidence = readiness?.behavioral_preview_evidence ?? null
  const overrideApplies = previewEvidenceOverride?.sourceDigest === (previewEvidence?.digest ?? null)
  const sealedPreview = overrideApplies ? previewEvidenceOverride.evidence : previewEvidence ?? latestPreviewEvidence
  const displayedPreviewMatchesCandidate = Boolean(!dirty && sealedPreview?.valid && readiness?.candidate && sealedPreview.candidate_digest === readiness.candidate.manifest_digest)
  const displayedPreviewMatchesLatest = Boolean(sealedPreview && latestPreviewEvidence && sealedPreview.id === latestPreviewEvidence.id && sealedPreview.digest === latestPreviewEvidence.digest)
  const concurrentPreviewMismatch = Boolean(displayedPreviewMatchesCandidate && latestPreviewEvidence && !displayedPreviewMatchesLatest)
  const currentPreview = displayedPreviewMatchesCandidate && displayedPreviewMatchesLatest
  const evidence = releaseEvidence(readiness, sealedPreview)
  const publishReady = Boolean(persona.has_unpublished_changes !== false && readiness?.permissions.publication_needed !== false && currentPreview && readiness?.ready && evidence && readiness.permissions.publish)
  const publicationCurrent = persona.has_unpublished_changes === false || readiness?.permissions.publication_needed === false
  const releaseStatus = publicationCurrent ? 'Published' : publishReady ? 'Ready to publish' : 'Checks required'
  const builtInCases = cases.filter((evaluationCase) => evaluationCase.kind === 'system' && evaluationCase.active)
  const existingCustomCases = cases.filter((evaluationCase) => evaluationCase.kind === 'custom')
  const caseContract = readiness?.evaluation_case_contract ?? DEFAULT_CASE_CONTRACT
  const reviewedPhraseCount = readiness?.phrase_audience_reviews.filter((review) => review.reviewed && review.decision === 'approved').length ?? 0
  const totalPhraseCount = readiness?.phrase_audience_reviews.length ?? 0
  const statusItems = useMemo(() => [
    { label: 'Behavioral preview', complete: currentPreview },
    { label: 'Release checks', complete: readiness?.evaluation_run?.passed === true },
    { label: 'Phrase audiences', complete: totalPhraseCount === 0 || reviewedPhraseCount === totalPhraseCount },
    { label: 'Human approval', complete: readiness?.approval?.decision === 'approved' && readiness.approval.valid },
  ], [currentPreview, readiness, reviewedPhraseCount, totalPhraseCount])

  const disabled = dirty || action !== null || parentBusy
  const selectedRunIsCurrent = selectedRun?.id === readiness?.evaluation_run?.id
  const activeRunRecoverable = selectedRunIsCurrent && selectedRun != null && !TERMINAL_RUN_STATUSES.has(selectedRun.status) && selectedRun.execution.recoverable

  return (
    <article className="panel persona-release" aria-busy={loading || action !== null}>
      <header className="persona-release-heading">
        <div><p className="eyebrow">Release checks</p><h3>Review the exact assistant before people use it.</h3><p>Preview a realistic answer, run the saved checks, and record a human decision for this revision.</p></div>
        <span className={`coach-status ${publishReady || publicationCurrent ? 'is-green' : 'is-gold'}`}>{releaseStatus}</span>
      </header>

      <ol className="persona-release-progress" aria-label="Release progress">
        {statusItems.map((item, index) => <li key={item.label} className={item.complete ? 'is-complete' : ''}><span aria-hidden="true">{item.complete ? '✓' : index + 1}</span><small>{item.label}</small></li>)}
      </ol>

      {error && <div className="persona-release-alert is-error" role="alert"><span>{error}</span><Button size="compact" variant="secondary" onClick={() => void loadReleaseState()}>Refresh release checks</Button></div>}
      {notice && <p className="persona-release-alert is-success" role="status">{notice}</p>}
      {dirty && <p className="persona-release-alert is-note" role="note">Save or discard all assistant changes before running release checks. Checks are tied to one exact saved revision.</p>}
      {loading ? <p className="persona-release-loading" role="status">Loading release checks…</p> : <>
        <section className="persona-release-step" aria-labelledby="behavioral-preview-title">
          <header><div><span>1</span><div><h4 id="behavioral-preview-title">Preview one realistic answer</h4><p>Use fictional details. Participant household data is never loaded into this preview.</p></div></div><StepState complete={currentPreview} label={currentPreview ? 'Reviewed' : 'Required'} /></header>
          <label className="coach-sample-prompt"><span>Behavioral preview question</span><textarea rows={3} maxLength={2000} value={samplePrompt} onChange={(event) => onSamplePromptChange(event.target.value)} placeholder="Ask the kind of question a participant will bring." /><small>Your question is sent to the configured model. Do not paste participant names, messages, or financial information.</small></label>
          <div className="persona-release-actions"><Button variant="secondary" onClick={onPreview} disabled={disabled || readiness?.permissions.publish !== true}>{previewPending ? 'Running preview…' : 'Run exact preview'}</Button></div>
          {readiness?.permissions.publish === false && <p className="coach-inline-note">A workspace owner or authorized publisher must run and save behavioral preview evidence.</p>}
          {preview && (!sealedPreview || preview.status !== 'ready') && <PreviewSummary preview={preview} current={currentPreview} />}
          {concurrentPreviewMismatch && <div className="persona-release-alert is-note" role="alert"><span>Another live preview was saved for this draft after the one shown below. Review the latest saved answer before publishing.</span>{latestPreviewEvidence && <Button size="compact" variant="secondary" onClick={() => setPreviewEvidenceOverride({ sourceDigest: previewEvidence?.digest ?? null, evidence: latestPreviewEvidence })}>Show latest saved preview</Button>}</div>}
          {sealedPreview && <BehavioralPreviewEvidence evidence={sealedPreview} current={currentPreview} superseded={concurrentPreviewMismatch} />}
        </section>

        <section className="persona-release-step" aria-labelledby="guardrail-checks-title">
          <header><div><span>2</span><div><h4 id="guardrail-checks-title">Run release checks</h4><p>Required system checks inspect the saved configuration and fixed safety policy without calling the assistant model. The preview above and any custom scenarios below exercise live assistant behavior.</p></div></div><StepState complete={readiness?.evaluation_run?.passed === true} label={readiness?.evaluation_run?.passed ? 'Passed' : 'Required'} /></header>
          <div className="persona-release-case-list">{builtInCases.map((evaluationCase) => <GuardrailCase key={evaluationCase.system_key ?? evaluationCase.id} evaluationCase={evaluationCase} />)}</div>
          <CustomCaseManager
            cases={existingCustomCases}
            canManage={readiness?.permissions.manage_cases === true}
            disabled={disabled}
            action={action}
            open={caseFormOpen}
            name={caseName}
            prompt={casePrompt}
            assertions={assertionDrafts}
            contract={caseContract}
            onOpenChange={setCaseFormOpen}
            onNameChange={setCaseName}
            onPromptChange={setCasePrompt}
            onAssertionsChange={setAssertionDrafts}
            onCreate={() => void createCase()}
            onRetire={(evaluationCase) => void retireCase(evaluationCase)}
          />
          <div className="persona-release-actions">{readiness?.permissions.run_evaluation ? <Button onClick={() => void runChecks()} disabled={disabled}>{action === 'run' ? activeRunRecoverable ? 'Recovering evaluation…' : readiness.evaluation_run?.status === 'pending' || readiness.evaluation_run?.status === 'running' ? 'Checking saved evaluation…' : 'Running checks…' : activeRunRecoverable ? 'Recover stalled evaluation' : readiness.evaluation_run?.status === 'pending' || readiness.evaluation_run?.status === 'running' ? 'Check saved evaluation status' : readiness.evaluation_run ? 'Run checks again' : 'Run checks for this draft'}</Button> : <p className="coach-inline-note">A workspace owner or editor must run these checks.</p>}</div>
          {selectedRun && <RunResult run={selectedRun} />}
          {runs.length > 1 && <details className="persona-release-details"><summary>Earlier check runs ({runs.length - 1})</summary><div className="persona-release-run-history">{runs.filter((run) => run.id !== selectedRun?.id).map((run) => <button type="button" key={run.id} onClick={() => void selectRun(run.id)}><span>{formatDate(run.completed_at ?? run.started_at)}</span><StepState complete={run.passed} label={run.status} /></button>)}</div></details>}
        </section>

        <section className="persona-release-step" aria-labelledby="phrase-review-title">
          <header><div><span>3</span><div><h4 id="phrase-review-title">Review phrases for this audience</h4><p>Each phrase must be appropriate for the exact audience and community context sealed with this draft.</p></div></div><StepState complete={totalPhraseCount === 0 || reviewedPhraseCount === totalPhraseCount} label={totalPhraseCount === 0 ? 'No phrases' : `${reviewedPhraseCount}/${totalPhraseCount} approved`} /></header>
          {readiness?.candidate ? <><AudienceSnapshot readiness={readiness} />{totalPhraseCount === 0 ? <p className="persona-release-empty">This draft has no audience-specific phrases to review.</p> : <div className="persona-release-phrase-list">{readiness.phrase_audience_reviews.map((review) => <PhraseAudienceReview key={review.artifact_id} review={review} canReview={readiness.permissions.review_phrase_audiences} disabled={disabled} onReview={(decision) => void reviewPhrase(review.artifact_id, decision)} />)}</div>}</> : <p className="persona-release-empty">Run the release checks to prepare this draft and open its phrase audience review.</p>}
        </section>

        <section className="persona-release-step" aria-labelledby="human-approval-title">
          <header><div><span>4</span><div><h4 id="human-approval-title">Approve the passed evaluation</h4><p>A workspace owner or reviewer must approve the exact intact result.</p></div></div><StepState complete={readiness?.approval?.decision === 'approved' && readiness.approval.valid} label={readiness?.approval?.decision ?? 'Required'} /></header>
          {!selectedRun ? <p className="persona-release-empty">Run the release checks first.</p> : !selectedRunIsCurrent ? <p className="persona-release-empty">This is an earlier run kept for reference. Select the latest run before recording a release decision.</p> : !selectedRun.passed ? <p className="persona-release-empty">Only a complete passed run can be approved. Fix the draft or failed check, then run the suite again.</p> : selectedRun.approval ? <p className="persona-release-review-meta">{humanize(selectedRun.approval.decision)} by {selectedRun.approval.reviewer.full_name}{selectedRun.approval.reviewer_role ? ` (${humanize(selectedRun.approval.reviewer_role)})` : ''} · {formatDate(selectedRun.approval.reviewed_at)}{selectedRun.approval.self_review ? ' · sole-owner self review' : ''}</p> : readiness?.permissions.review_evaluations ? <><p className="coach-inline-note">Review every result above before recording this decision. A rejection is permanent for this run.</p><div className="persona-release-actions"><Button onClick={() => void reviewRun('approved')} disabled={disabled}>{action === 'approve' ? 'Approving…' : 'Approve passed evaluation'}</Button><Button variant="danger" onClick={() => void reviewRun('rejected')} disabled={disabled}>{action === 'reject_run' ? 'Rejecting…' : 'Reject evaluation'}</Button></div>{!readiness.permissions.sole_owner_self_review && selectedRun.requested_by && <small className="persona-release-role-note">If {selectedRun.requested_by.full_name} ran these checks, a different owner or reviewer must approve them.</small>}</> : <p className="coach-inline-note">Waiting for a workspace owner or reviewer.</p>}
        </section>

        <section className="persona-release-step is-publish" aria-labelledby="publish-title">
          <header><div><span>5</span><div><h4 id="publish-title">Publish this assistant version</h4><p>Publishing records the approved candidate, evaluation, phrase reviews, and human decision as one version.</p></div></div><StepState complete={publishReady} label={publishReady ? 'Ready' : persona.has_unpublished_changes === false ? 'Published' : 'Blocked'} /></header>
          {readiness?.blockers.length ? <ul className="persona-release-blockers">{readiness.blockers.map((blocker) => <li key={blocker}>{blocker}</li>)}</ul> : null}
          {persona.assignments.length > 0 && <p className="coach-inline-note">Publishing updates future participant messages in {persona.assignments.length} assigned cohort{persona.assignments.length === 1 ? '' : 's'}. You will confirm this impact before it changes.</p>}
          <div className="persona-release-actions"><Button onClick={() => evidence && onPublish(evidence)} disabled={!publishReady || parentBusy || action !== null}>{publishPending ? 'Publishing…' : persona.published_version ? 'Publish next version' : 'Publish first version'}</Button></div>
          {persona.has_unpublished_changes === false && <p className="coach-inline-note">This saved revision is already published. Make and save a change before preparing another release.</p>}
          {readiness?.permissions.publication_needed !== false && !readiness?.permissions.publish && <p className="coach-inline-note">A workspace owner or authorized publisher must publish the approved version.</p>}
          {readiness?.candidate && <details className="persona-release-details"><summary>Release evidence</summary><dl className="persona-release-evidence"><div><dt>Draft revision</dt><dd>{readiness.candidate.draft_revision}</dd></div><div><dt>Candidate</dt><dd>{shortDigest(readiness.candidate.manifest_digest)}</dd></div><div><dt>Behavioral preview</dt><dd>{shortDigest(readiness.behavioral_preview_evidence?.digest)}</dd></div><div><dt>Evaluation</dt><dd>{shortDigest(readiness.evaluation_run?.run_digest)}</dd></div><div><dt>Approval</dt><dd>{shortDigest(readiness.approval?.approval_digest)}</dd></div></dl></details>}
        </section>
      </>}
    </article>
  )
}

function CustomCaseManager({ cases, canManage, disabled, action, open, name, prompt, assertions, contract, onOpenChange, onNameChange, onPromptChange, onAssertionsChange, onCreate, onRetire }: {
  cases: AdminPersonaEvaluationCase[]
  canManage: boolean
  disabled: boolean
  action: ReleaseAction
  open: boolean
  name: string
  prompt: string
  assertions: AssertionDraft[]
  contract: AdminPersonaEvaluationCaseContract
  onOpenChange: (open: boolean) => void
  onNameChange: (value: string) => void
  onPromptChange: (value: string) => void
  onAssertionsChange: (value: AssertionDraft[]) => void
  onCreate: () => void
  onRetire: (evaluationCase: AdminPersonaEvaluationCase) => void
}) {
  const activeCount = cases.filter((evaluationCase) => evaluationCase.active).length
  const atCapacity = activeCount >= contract.max_active_custom_cases
  return <section className="persona-release-custom" aria-labelledby="custom-scenarios-title">
    <header><div><h5 id="custom-scenarios-title">Live-model scenarios</h5><p>Add fictional questions that should behave a specific way. Each scenario runs against the configured behavioral model and fails when only fallback output is available.</p></div><span>{activeCount}/{contract.max_active_custom_cases} active</span></header>
    {cases.length > 0 && <div className="persona-release-custom-list">{cases.map((evaluationCase) => <article key={evaluationCase.id} className={!evaluationCase.active ? 'is-retired' : ''}><div><strong>{evaluationCase.name}</strong><small>{evaluationCase.active ? 'Live model · included in the next run' : `Retired · ${formatDate(evaluationCase.retired_at)}`}</small></div><details><summary>Scenario and assertions</summary><p>{evaluationCase.prompt}</p><ul>{evaluationCase.assertions.map((assertion, index) => <li key={`${assertion.type}-${index}`}>{assertionLabel(assertion)}</li>)}</ul>{!evaluationCase.active && evaluationCase.retired_by && <small>Retired by {evaluationCase.retired_by.full_name}. Evidence remains in earlier run results.</small>}</details>{evaluationCase.active && canManage && evaluationCase.id && <Button size="compact" variant="danger" disabled={disabled} onClick={() => onRetire(evaluationCase)}>{action === `retire_case:${evaluationCase.id}` ? 'Retiring…' : 'Retire scenario'}</Button>}</article>)}</div>}
    {cases.length === 0 && <p className="persona-release-empty">No custom live-model scenarios yet. The required configuration and policy checks still run every time.</p>}
    {canManage ? <>
      {!open && <div className="persona-release-actions"><Button size="compact" variant="secondary" disabled={disabled || atCapacity} onClick={() => onOpenChange(true)}>Add live-model scenario</Button>{atCapacity && <small>Retire an active scenario before adding another.</small>}</div>}
      {open && <fieldset className="persona-release-case-form" disabled={disabled}>
        <legend>Add a live-model scenario</legend>
        <p>Use invented details only. The prompt will be sent to the configured model whenever the release suite runs.</p>
        <label><span>Scenario name</span><input maxLength={contract.name_max_chars} value={name} onChange={(event) => onNameChange(event.target.value)} placeholder="Explains a tradeoff without shame" /></label>
        <label><span>Fictional prompt</span><textarea rows={4} maxLength={contract.prompt_max_chars} value={prompt} onChange={(event) => onPromptChange(event.target.value)} placeholder="I have $200 left this month. How should I decide whether to attend an event?" /><small>{prompt.length}/{contract.prompt_max_chars} characters</small></label>
        <div className="persona-release-assertions"><div><strong>What the answer must prove</strong><small>Use {contract.assertions_min}–{contract.assertions_max} typed assertions. Every assertion must pass, and fallback output always fails the scenario.</small></div>{assertions.map((assertion, index) => <AssertionEditor key={assertion.id} assertion={assertion} index={index} removable={assertions.length > contract.assertions_min} contract={contract} onChange={(next) => onAssertionsChange(assertions.map((current) => current.id === assertion.id ? next : current))} onRemove={() => onAssertionsChange(assertions.filter((current) => current.id !== assertion.id))} />)}{assertions.length < contract.assertions_max && <Button size="compact" variant="secondary" onClick={() => onAssertionsChange([...assertions, newAssertionDraft(contract.assertion_types.includes('includes') ? 'includes' : contract.assertion_types[0] ?? 'not_fallback')])}>Add assertion</Button>}</div>
        <div className="persona-release-actions"><Button onClick={onCreate}>{action === 'create_case' ? 'Saving scenario…' : 'Save scenario'}</Button><Button variant="secondary" onClick={() => onOpenChange(false)}>Cancel</Button></div>
      </fieldset>}
    </> : <p className="coach-inline-note">A workspace owner or editor can add and retire live-model scenarios.</p>}
  </section>
}

function AssertionEditor({ assertion, index, removable, contract, onChange, onRemove }: {
  assertion: AssertionDraft
  index: number
  removable: boolean
  contract: AdminPersonaEvaluationCaseContract
  onChange: (value: AssertionDraft) => void
  onRemove: () => void
}) {
  const needsList = assertion.type === 'includes_any' || assertion.type === 'excludes_any'
  const needsValue = assertion.type === 'includes' || assertion.type === 'excludes' || assertion.type === 'max_chars'
  return <fieldset className="persona-release-assertion">
    <legend>Assertion {index + 1}</legend>
    <label><span>Check</span><select aria-label={`Assertion ${index + 1} type`} value={assertion.type} onChange={(event) => onChange({ ...assertion, type: event.target.value as AssertionDraft['type'], value: '' })}>{ASSERTION_OPTIONS.filter((option) => contract.assertion_types.includes(option.value)).map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</select></label>
    {needsValue && <label><span>{assertion.type === 'max_chars' ? 'Maximum characters' : 'Text to check'}</span><input aria-label={`Assertion ${index + 1} value`} type={assertion.type === 'max_chars' ? 'number' : 'text'} min={assertion.type === 'max_chars' ? contract.max_chars_range.min : undefined} max={assertion.type === 'max_chars' ? contract.max_chars_range.max : undefined} maxLength={assertion.type === 'max_chars' ? undefined : contract.assertion_value_max_chars} value={assertion.value} onChange={(event) => onChange({ ...assertion, value: event.target.value })} /></label>}
    {needsList && <label><span>Text choices, one per line</span><textarea aria-label={`Assertion ${index + 1} values`} rows={3} maxLength={contract.assertion_values_max * (contract.assertion_value_max_chars + 1)} value={assertion.value} onChange={(event) => onChange({ ...assertion, value: event.target.value })} /><small>1–{contract.assertion_values_max} choices, up to {contract.assertion_value_max_chars} characters each.</small></label>}
    {!needsList && !needsValue && <p>{assertion.type === 'not_fallback' ? 'Requires a real model answer rather than fallback output.' : assertion.type === 'excludes_configured_phrases' ? 'Keeps configured community phrases out of this answer.' : 'Rejects cultural language that the coach did not approve.'}</p>}
    {removable && <Button size="compact" variant="danger" onClick={onRemove}>Remove assertion {index + 1}</Button>}
  </fieldset>
}

function GuardrailCase({ evaluationCase }: { evaluationCase: AdminPersonaEvaluationCase }) {
  return <details className="persona-release-case"><summary><span>{evaluationCase.name}</span><small>{evaluationCase.required ? 'Required policy check' : evaluationCase.active ? 'Included' : 'Retired'}</small></summary><div><p>This scenario checks the saved configuration and fixed system policy. It does not call the live assistant model.</p><p>{evaluationCase.prompt}</p><ul>{evaluationCase.assertions.map((assertion, index) => <li key={`${assertion.type}-${index}`}>{assertionLabel(assertion)}</li>)}</ul></div></details>
}

function RunResult({ run }: { run: AdminPersonaEvaluationRun }) {
  const active = !TERMINAL_RUN_STATUSES.has(run.status)
  return <section className={`persona-release-run is-${run.status}`} aria-label="Release check results"><header><div><strong>{run.status === 'passed' ? 'All release checks passed' : run.status === 'failed' ? 'Release checks need attention' : run.status === 'error' ? 'Checks could not finish' : run.execution.recoverable ? 'Evaluation needs recovery' : run.status === 'pending' ? 'Evaluation is queued' : 'Checks are running'}</strong><small>{run.requested_by ? `Run by ${run.requested_by.full_name}` : 'Workspace evaluation'} · {formatDate(run.completed_at ?? run.started_at ?? run.enqueued_at)}</small></div><StepState complete={run.passed} label={run.execution.recoverable ? 'Recovery available' : run.status} /></header>{active && <p className={`persona-release-execution ${run.execution.recoverable ? 'is-recoverable' : ''}`}>{run.execution.recoverable ? 'The worker lease expired before this saved run finished. Recovery safely replays the same request and does not create another run.' : run.execution.active_lease ? `A worker holds the active lease. Status checks use the saved run${run.execution.lease_expires_at ? ` through ${formatDate(run.execution.lease_expires_at)}` : ''}.` : 'The saved run is waiting for a worker. Checking status will not create another run.'}</p>}{run.results?.map((result) => <details key={result.id} className="persona-release-result" open={result.status !== 'passed'}><summary><span>{result.case.name}</span><StepState complete={result.status === 'passed' && !result.fallback_only} label={result.fallback_only ? 'Fallback output' : result.status} /></summary><div><div><small>{result.case.kind === 'system' ? 'Policy scenario' : 'Live-model prompt'}</small><p>{result.case.prompt}</p></div><div><small>{result.case.kind === 'system' ? 'Configuration and policy result' : 'Live-model answer'}</small><blockquote>{result.output}</blockquote></div><ul>{result.assertion_results.map((assertion, index) => <li key={`${assertion.type}-${index}`} className={assertion.passed ? 'is-passed' : 'is-failed'}>{assertion.passed ? 'Passed' : 'Failed'}: {assertionLabel(result.case.assertions[index] ?? { type: assertion.type })}</li>)}</ul></div></details>)}</section>
}

function PhraseAudienceReview({ review, canReview, disabled, onReview }: {
  review: AdminPersonaAudienceReview
  canReview: boolean
  disabled: boolean
  onReview: (decision: 'approved' | 'rejected') => void
}) {
  const approved = review.reviewed && review.review_state === 'approved'
  const hasPriorEvidence = review.reviewer != null && review.reviewed_at != null
  const freshReviewLabel = hasPriorEvidence ? ' with fresh review' : ''
  const stateLabel = review.review_state === 'approved' ? 'Approved'
    : review.review_state === 'rejected' ? 'Rejected'
      : review.review_state === 'stale_authority' ? 'Reviewer access changed'
        : review.review_state === 'invalid' ? 'Evidence invalid'
          : 'Needs review'
  return <article className="persona-release-phrase"><header><div><strong>{review.phrase.text}</strong><small>{humanize(review.provenance.kind)}</small></div><StepState complete={approved} label={stateLabel} /></header><p>{review.phrase.meaning}</p><dl><div><dt>Use for</dt><dd>{review.phrase.allowed_contexts.map(humanize).join(', ') || 'No approved contexts'}</dd></div><div><dt>Never use for</dt><dd>{review.phrase.prohibited_contexts.map(humanize).join(', ') || 'No prohibited contexts'}</dd></div><div><dt>Frequency</dt><dd>{humanize(review.phrase.frequency)}</dd></div><div><dt>Caution</dt><dd>{review.phrase.caution || 'None recorded'}</dd></div></dl>{hasPriorEvidence && <p className="persona-release-review-meta">{humanize(review.decision ?? 'reviewed')} by {review.reviewer?.full_name ?? 'workspace reviewer'}{review.reviewer_role ? ` (${humanize(review.reviewer_role)})` : ''} · {formatDate(review.reviewed_at)}{review.self_review ? ' · sole-owner self review' : ''}</p>}{review.review_state === 'stale_authority' && <p className="persona-release-alert is-note" role="note">This evidence no longer authorizes release because the prior reviewer does not have current review access. A current reviewer must record fresh evidence.</p>}{review.review_state === 'invalid' && <p className="persona-release-alert is-error" role="alert">The prior review evidence did not pass its integrity check. A current reviewer must record fresh evidence.</p>}{review.review_state === 'rejected' && <p className="coach-inline-note">The latest authorized decision rejects this phrase for the sealed audience. A current reviewer may record a fresh decision after review.</p>}{!approved && canReview ? <div className="persona-release-actions"><Button size="compact" onClick={() => onReview('approved')} disabled={disabled}>Approve{freshReviewLabel} for this audience</Button><Button size="compact" variant="danger" onClick={() => onReview('rejected')} disabled={disabled}>Reject{freshReviewLabel}</Button></div> : !approved ? <p className="coach-inline-note">Waiting for a workspace owner or reviewer.</p> : null}</article>
}

function AudienceSnapshot({ readiness }: { readiness: AdminPersonaReleaseReadiness }) {
  const audience = readiness.candidate?.audience_snapshot
  if (!audience) return null
  return <div className="persona-release-audience" role="note"><strong>Audience sealed with this release</strong><p>{audience.audience}</p><dl><div><dt>Participant term</dt><dd>{audience.client_term}</dd></div><div><dt>Locale context</dt><dd>{audience.culture.locale_label || 'No locale label'}</dd></div><div><dt>Community context</dt><dd>{audience.culture.context || 'No added context'}</dd></div>{audience.culture.local_realities.length > 0 && <div><dt>Local realities</dt><dd>{audience.culture.local_realities.join('; ')}</dd></div>}{audience.culture.references.length > 0 && <div><dt>Reviewed references</dt><dd>{audience.culture.references.join('; ')}</dd></div>}</dl></div>
}

function BehavioralPreviewEvidence({ evidence, current, superseded }: { evidence: AdminPersonaBehavioralPreviewEvidence; current: boolean; superseded: boolean }) {
  return <section className="persona-release-preview-evidence" aria-label="Sealed behavioral preview evidence"><header><div><strong>Saved live-model preview</strong><small>{evidence.model} · {formatDate(evidence.generated_at)}</small></div><StepState complete={current} label={current ? 'Evidence intact' : superseded ? 'Newer preview saved' : evidence.valid ? 'Earlier candidate' : 'Evidence invalid'} /></header><div><small>Fictional prompt</small><p>{evidence.prompt}</p></div><div><small>Model answer</small><blockquote>{evidence.output}</blockquote></div><dl><div><dt>Privacy scope</dt><dd>No saved participant or household data was used.</dd></div><div><dt>Generated by</dt><dd>{evidence.generated_by.full_name}</dd></div><div><dt>Evidence</dt><dd>{shortDigest(evidence.digest)}</dd></div></dl></section>
}

function PreviewSummary({ preview, current }: { preview: AdminPersonaPreview; current: boolean }) {
  return <section className={`coach-preview-result is-${preview.status}`} aria-label="Exact draft preview"><header><div><strong>{preview.status === 'ready' ? 'Behavioral sample ready' : preview.status === 'safety_only' ? 'Safety response only' : 'Behavioral preview unavailable'}</strong><small>Draft revision {preview.draft_revision} · {humanize(preview.source)}</small></div><StepState complete={current} label={current ? 'Current' : 'Not publishable'} /></header><p>{preview.notice}</p>{preview.sample_prompt && <div><small>Sample question</small><p>{preview.sample_prompt}</p></div>}{preview.sample_reply && <blockquote>{preview.sample_reply}</blockquote>}{!preview.sample_reply && preview.status === 'unavailable' && <p className="coach-inline-note">No generated answer is shown. Publishing stays locked until a successful behavioral preview checks this exact draft.</p>}<details><summary>Compiled instructions for this revision</summary><pre>{preview.rendered_instructions}</pre></details><small>Guardrails applied: {preview.guardrails_applied ? 'Yes' : 'No'} · Generated {formatDate(preview.generated_at)}</small></section>
}

function StepState({ complete, label }: { complete: boolean; label: string }) {
  return <span className={`persona-release-state ${complete ? 'is-complete' : ''}`}>{label}</span>
}

function releaseEvidence(readiness: AdminPersonaReleaseReadiness | null, displayedPreview: AdminPersonaBehavioralPreviewEvidence | null): PersonaPublishEvidence | null {
  const candidateDigest = readiness?.candidate?.manifest_digest
  const runDigest = readiness?.evaluation_run?.run_digest
  const approvalDigest = readiness?.approval?.approval_digest
  const latestPreview = readiness?.behavioral_preview_evidence
  const behavioralPreviewDigest = displayedPreview?.digest
  if (!candidateDigest || !runDigest || !approvalDigest || !behavioralPreviewDigest || !latestPreview ||
    displayedPreview.id !== latestPreview.id || behavioralPreviewDigest !== latestPreview.digest ||
    displayedPreview.candidate_digest !== candidateDigest) return null
  return { release_candidate_digest: candidateDigest, evaluation_run_digest: runDigest, evaluation_approval_digest: approvalDigest, behavioral_preview_digest: behavioralPreviewDigest }
}

function newAssertionDraft(type: AssertionDraft['type']): AssertionDraft {
  return { id: newRequestId(), type, value: '' }
}

function validateCaseDraft(name: string, prompt: string, drafts: AssertionDraft[], contract: AdminPersonaEvaluationCaseContract): { error: string | null; assertions: AdminPersonaEvaluationAssertion[] } {
  if (!name.trim()) return { error: 'Enter a name for the live-model scenario.', assertions: [] }
  if (name.trim().length > contract.name_max_chars) return { error: `Scenario names must be ${contract.name_max_chars} characters or fewer.`, assertions: [] }
  if (!prompt.trim()) return { error: 'Enter a fictional prompt for the live-model scenario.', assertions: [] }
  if (prompt.trim().length > contract.prompt_max_chars) return { error: `Scenario prompts must be ${contract.prompt_max_chars.toLocaleString()} characters or fewer.`, assertions: [] }
  if (drafts.length < contract.assertions_min || drafts.length > contract.assertions_max) return { error: `Add between ${contract.assertions_min} and ${contract.assertions_max} typed assertions.`, assertions: [] }
  const assertions: AdminPersonaEvaluationAssertion[] = []
  for (const [index, draft] of drafts.entries()) {
    if (!contract.assertion_types.includes(draft.type)) return { error: `Assertion ${index + 1} uses a check that is no longer supported.`, assertions: [] }
    if (draft.type === 'includes' || draft.type === 'excludes') {
      const value = draft.value.trim()
      if (!value || value.length > contract.assertion_value_max_chars) return { error: `Assertion ${index + 1} needs text between 1 and ${contract.assertion_value_max_chars} characters.`, assertions: [] }
      assertions.push({ type: draft.type, value })
    } else if (draft.type === 'includes_any' || draft.type === 'excludes_any') {
      const values = draft.value.split('\n').map((value) => value.trim()).filter(Boolean)
      if (values.length < 1 || values.length > contract.assertion_values_max || values.some((value) => value.length > contract.assertion_value_max_chars)) return { error: `Assertion ${index + 1} needs 1–${contract.assertion_values_max} choices, each ${contract.assertion_value_max_chars} characters or fewer.`, assertions: [] }
      assertions.push({ type: draft.type, values })
    } else if (draft.type === 'max_chars') {
      const value = Number(draft.value)
      if (!Number.isInteger(value) || value < contract.max_chars_range.min || value > contract.max_chars_range.max) return { error: `Assertion ${index + 1} needs a whole-number limit from ${contract.max_chars_range.min.toLocaleString()} to ${contract.max_chars_range.max.toLocaleString()}.`, assertions: [] }
      assertions.push({ type: draft.type, value })
    } else {
      assertions.push({ type: draft.type })
    }
  }
  return { error: null, assertions }
}

function replaceRun(current: AdminPersonaEvaluationRun[], next: AdminPersonaEvaluationRun) {
  return [next, ...current.filter((run) => run.id !== next.id)]
}

function assertionLabel(assertion: AdminPersonaEvaluationAssertion) {
  switch (assertion.type) {
    case 'includes': return `Answer includes “${assertion.value}”`
    case 'excludes': return `Answer does not include “${assertion.value}”`
    case 'includes_any': return `Answer includes at least one of: ${assertion.values?.join(', ')}`
    case 'excludes_any': return `Answer excludes: ${assertion.values?.join(', ')}`
    case 'max_chars': return `Answer stays within ${assertion.value} characters`
    case 'not_fallback': return 'Uses the evaluated response, not fallback output'
    case 'excludes_configured_phrases': return 'Keeps configured phrases out of crisis responses'
    case 'no_unapproved_cultural_language': return 'Uses no unapproved cultural language'
  }
}

function errorMessage(caught: unknown, fallback: string) {
  if (caught instanceof ApiRequestError) return caught.message || caught.errors.join(', ') || fallback
  if (caught instanceof Error) return caught.message || fallback
  return fallback
}

function newRequestId() {
  return globalThis.crypto?.randomUUID?.() ?? `release-${Date.now()}-${Math.random().toString(16).slice(2)}`
}

function formatDate(value: string | null | undefined) {
  return value ? new Date(value).toLocaleString() : 'Not completed'
}

function shortDigest(value: string | null | undefined) {
  return value ? `${value.slice(0, 12)}…` : 'Not available'
}

function humanize(value: string) {
  return value.replace(/_/g, ' ').replace(/\b\w/g, (letter) => letter.toUpperCase())
}

function delay(milliseconds: number) {
  return new Promise((resolve) => globalThis.setTimeout(resolve, milliseconds))
}
