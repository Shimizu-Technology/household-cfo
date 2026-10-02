import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  ApiRequestError,
  fetchAdminPersonaEvaluationCases,
  fetchAdminPersonaEvaluationRun,
  fetchAdminPersonaEvaluationRuns,
  fetchAdminPersonaReleaseReadiness,
  reviewAdminPersonaAudience,
  reviewAdminPersonaEvaluation,
  runAdminPersonaEvaluation,
} from '../api'
import type {
  AdminPersonaDetail,
  AdminPersonaEvaluationAssertion,
  AdminPersonaEvaluationCase,
  AdminPersonaEvaluationRun,
  AdminPersonaPreview,
  AdminPersonaReleaseReadiness,
} from '../api'
import { Button } from './Button'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

const TERMINAL_RUN_STATUSES = new Set(['passed', 'failed', 'error'])
const RUN_POLL_INTERVAL_MS = 1_750
const RUN_POLL_LIMIT = 60

type ReleaseAction = 'run' | 'approve' | 'reject_run' | `phrase:${string}:approved` | `phrase:${string}:rejected` | null

export type PersonaPublishEvidence = {
  release_candidate_digest: string
  evaluation_run_digest: string
  evaluation_approval_digest: string
}

type PersonaReleasePanelProps = {
  persona: AdminPersonaDetail
  preview: AdminPersonaPreview | null
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

  const pollRun = useCallback(async (runId: number) => {
    const personaId = persona.id
    for (let attempt = 0; attempt < RUN_POLL_LIMIT; attempt += 1) {
      await delay(RUN_POLL_INTERVAL_MS)
      if (!mountedRef.current || personaIdRef.current !== personaId) return null
      try {
        const next = await fetchAdminPersonaEvaluationRun(personaId, runId)
        if (!mountedRef.current || personaIdRef.current !== personaId) return null
        setSelectedRun(next)
        setRuns((current) => replaceRun(current, next))
        if (TERMINAL_RUN_STATUSES.has(next.status)) return next
      } catch (caught) {
        if (caught instanceof ApiRequestError && caught.status === 404) return null
      }
    }
    return null
  }, [persona.id])

  async function runChecks() {
    if (!readiness?.permissions.run_evaluation || dirty || action || parentBusy) return
    const ticket = mutationLifecycle.begin()
    const requestId = runRequestId ?? newRequestId()
    setRunRequestId(requestId)
    setAction('run')
    setError(null)
    setNotice(null)
    try {
      const response = await runAdminPersonaEvaluation(persona.id, requestId)
      if (!mutationLifecycle.isCurrent(ticket) || personaIdRef.current !== persona.id) return
      let nextRun = response.evaluation_run
      setSelectedRun(nextRun)
      setRuns((current) => replaceRun(current, nextRun))
      if (!TERMINAL_RUN_STATUSES.has(nextRun.status)) nextRun = await pollRun(nextRun.id) ?? nextRun
      if (!mutationLifecycle.isCurrent(ticket) || personaIdRef.current !== persona.id) return
      const terminal = TERMINAL_RUN_STATUSES.has(nextRun.status)
      if (terminal) setRunRequestId(null)
      await loadReleaseState({ quiet: true, preferredRunId: nextRun.id })
      if (!mutationLifecycle.isCurrent(ticket)) return
      setNotice(!terminal
        ? 'The automated checks are still running. Refresh this page or check the run again; its saved request will resume without creating a duplicate.'
        : nextRun.status === 'passed'
        ? 'Automated guardrail checks passed for this exact saved draft.'
        : nextRun.status === 'failed'
          ? 'One or more automated guardrail checks failed. Review the results before running them again.'
          : 'The automated checks could not finish. Review the result and try again.')
    } catch (caught) {
      if (!mutationLifecycle.isCurrent(ticket) || personaIdRef.current !== persona.id) return
      const reconciled = await loadReleaseState({ quiet: true })
      if (!mutationLifecycle.isCurrent(ticket)) return
      const latest = reconciled?.runs[0]
      if (latest && latest.id !== runs[0]?.id) {
        setSelectedRun(reconciled?.selectedRun ?? latest)
        setNotice('The request may have completed while the connection was interrupted. The latest check result is loaded below.')
      } else {
        setError(`${errorMessage(caught, 'The automated guardrail checks could not run.')} Refresh the release checks or retry; the same request will not create a duplicate.`)
      }
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
    if (!candidate || !review || review.reviewed || !readiness.permissions.review_phrase_audiences || action || parentBusy) return
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

  const currentPreview = Boolean(!dirty && preview?.status === 'ready' && persona.preview_required === false && preview.digest === persona.preview?.digest)
  const evidence = releaseEvidence(readiness)
  const publishReady = Boolean(currentPreview && readiness?.ready && evidence && readiness.permissions.publish)
  const builtInCases = cases.filter((evaluationCase) => evaluationCase.kind === 'system' && evaluationCase.active)
  const existingCustomCases = cases.filter((evaluationCase) => evaluationCase.kind === 'custom')
  const reviewedPhraseCount = readiness?.phrase_audience_reviews.filter((review) => review.reviewed && review.decision === 'approved').length ?? 0
  const totalPhraseCount = readiness?.phrase_audience_reviews.length ?? 0
  const statusItems = useMemo(() => [
    { label: 'Behavioral preview', complete: currentPreview },
    { label: 'Automated guardrails', complete: readiness?.evaluation_run?.passed === true },
    { label: 'Phrase audiences', complete: totalPhraseCount === 0 || reviewedPhraseCount === totalPhraseCount },
    { label: 'Human approval', complete: readiness?.approval?.decision === 'approved' && readiness.approval.valid },
  ], [currentPreview, readiness, reviewedPhraseCount, totalPhraseCount])

  const disabled = dirty || action !== null || parentBusy
  const savedPreviewNeedsReview = !dirty && !preview && persona.preview_required === false && Boolean(persona.preview)
  const selectedRunIsCurrent = selectedRun?.id === readiness?.evaluation_run?.id

  return (
    <article className="panel persona-release" aria-busy={loading || action !== null}>
      <header className="persona-release-heading">
        <div><p className="eyebrow">Release checks</p><h3>Review the exact assistant before people use it.</h3><p>One saved revision, one set of checks, and one human approval stay linked as release evidence.</p></div>
        <span className={`coach-status ${publishReady ? 'is-green' : 'is-gold'}`}>{publishReady ? 'Ready to publish' : 'Checks required'}</span>
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
          <div className="persona-release-actions"><Button variant="secondary" onClick={onPreview} disabled={disabled || !persona.permissions.publish}>{previewPending ? 'Running preview…' : 'Run exact preview'}</Button></div>
          {savedPreviewNeedsReview && <p className="coach-inline-note">This revision passed preview in another session. Run it here to review the actual answer before publishing.</p>}
          {preview && <PreviewSummary preview={preview} current={currentPreview} />}
        </section>

        <section className="persona-release-step" aria-labelledby="guardrail-checks-title">
          <header><div><span>2</span><div><h4 id="guardrail-checks-title">Run automated guardrail checks</h4><p>These fixed checks verify crisis boundaries, digital assistant disclosure, participant control, and cultural language limits. They do not replace the realistic preview above.</p></div></div><StepState complete={readiness?.evaluation_run?.passed === true} label={readiness?.evaluation_run?.passed ? 'Passed' : 'Required'} /></header>
          <div className="persona-release-case-list">{builtInCases.map((evaluationCase) => <GuardrailCase key={evaluationCase.system_key ?? evaluationCase.id} evaluationCase={evaluationCase} />)}</div>
          {existingCustomCases.length > 0 && <details className="persona-release-details"><summary>Existing custom checks ({existingCustomCases.length})</summary><div><p>Custom checks created previously remain part of the suite. New custom checks stay unavailable until they can exercise the real assistant behavior faithfully.</p>{existingCustomCases.map((evaluationCase) => <GuardrailCase key={evaluationCase.id} evaluationCase={evaluationCase} />)}</div></details>}
          <div className="persona-release-actions">{readiness?.permissions.run_evaluation ? <Button onClick={() => void runChecks()} disabled={disabled}>{action === 'run' ? 'Running checks…' : readiness.evaluation_run?.status === 'pending' || readiness.evaluation_run?.status === 'running' ? 'Check running evaluation' : readiness.evaluation_run ? 'Run checks again' : 'Run checks for this draft'}</Button> : <p className="coach-inline-note">A workspace owner or editor must run these checks.</p>}</div>
          {selectedRun && <RunResult run={selectedRun} />}
          {runs.length > 1 && <details className="persona-release-details"><summary>Earlier check runs ({runs.length - 1})</summary><div className="persona-release-run-history">{runs.filter((run) => run.id !== selectedRun?.id).map((run) => <button type="button" key={run.id} onClick={() => void selectRun(run.id)}><span>{formatDate(run.completed_at ?? run.started_at)}</span><StepState complete={run.passed} label={run.status} /></button>)}</div></details>}
        </section>

        <section className="persona-release-step" aria-labelledby="phrase-review-title">
          <header><div><span>3</span><div><h4 id="phrase-review-title">Review phrases for this audience</h4><p>Each phrase must be appropriate for the exact audience and community context sealed with this draft.</p></div></div><StepState complete={totalPhraseCount === 0 || reviewedPhraseCount === totalPhraseCount} label={totalPhraseCount === 0 ? 'No phrases' : `${reviewedPhraseCount}/${totalPhraseCount} approved`} /></header>
          {readiness?.candidate ? <><AudienceSnapshot readiness={readiness} />{totalPhraseCount === 0 ? <p className="persona-release-empty">This draft has no audience-specific phrases to review.</p> : <div className="persona-release-phrase-list">{readiness.phrase_audience_reviews.map((review) => <article key={review.artifact_id} className="persona-release-phrase"><header><div><strong>{review.phrase.text}</strong><small>{humanize(review.provenance.kind)}</small></div><StepState complete={review.reviewed && review.decision === 'approved'} label={review.decision ?? 'Needs review'} /></header><p>{review.phrase.meaning}</p><dl><div><dt>Use for</dt><dd>{review.phrase.allowed_contexts.map(humanize).join(', ') || 'No approved contexts'}</dd></div><div><dt>Never use for</dt><dd>{review.phrase.prohibited_contexts.map(humanize).join(', ') || 'No prohibited contexts'}</dd></div><div><dt>Frequency</dt><dd>{humanize(review.phrase.frequency)}</dd></div><div><dt>Caution</dt><dd>{review.phrase.caution || 'None recorded'}</dd></div></dl>{review.reviewed ? <p className="persona-release-review-meta">{humanize(review.decision ?? 'reviewed')} by {review.reviewer?.full_name ?? 'workspace reviewer'} · {formatDate(review.reviewed_at)}{review.self_review ? ' · sole-owner self review' : ''}</p> : readiness.permissions.review_phrase_audiences ? <div className="persona-release-actions"><Button size="compact" onClick={() => void reviewPhrase(review.artifact_id, 'approved')} disabled={disabled}>Approve for this audience</Button><Button size="compact" variant="danger" onClick={() => void reviewPhrase(review.artifact_id, 'rejected')} disabled={disabled}>Reject</Button></div> : <p className="coach-inline-note">Waiting for a workspace owner or reviewer.</p>}</article>)}</div>}</> : <p className="persona-release-empty">Run the automated checks to seal this draft and open its phrase audience review.</p>}
        </section>

        <section className="persona-release-step" aria-labelledby="human-approval-title">
          <header><div><span>4</span><div><h4 id="human-approval-title">Approve the passed evaluation</h4><p>A workspace owner or reviewer must approve the exact intact result.</p></div></div><StepState complete={readiness?.approval?.decision === 'approved' && readiness.approval.valid} label={readiness?.approval?.decision ?? 'Required'} /></header>
          {!selectedRun ? <p className="persona-release-empty">Run the automated guardrail checks first.</p> : !selectedRunIsCurrent ? <p className="persona-release-empty">This is an earlier run kept for reference. Select the latest run before recording a release decision.</p> : !selectedRun.passed ? <p className="persona-release-empty">Only a complete passed run can be approved. Fix the draft or failed check, then run the suite again.</p> : selectedRun.approval ? <p className="persona-release-review-meta">{humanize(selectedRun.approval.decision)} by {selectedRun.approval.reviewer.full_name} · {formatDate(selectedRun.approval.reviewed_at)}{selectedRun.approval.self_review ? ' · sole-owner self review' : ''}</p> : readiness?.permissions.review_evaluations ? <><p className="coach-inline-note">Review every result above before recording this decision. A rejection is permanent for this run.</p><div className="persona-release-actions"><Button onClick={() => void reviewRun('approved')} disabled={disabled}>{action === 'approve' ? 'Approving…' : 'Approve passed evaluation'}</Button><Button variant="danger" onClick={() => void reviewRun('rejected')} disabled={disabled}>{action === 'reject_run' ? 'Rejecting…' : 'Reject evaluation'}</Button></div>{!readiness.permissions.sole_owner_self_review && selectedRun.requested_by && <small className="persona-release-role-note">If {selectedRun.requested_by.full_name} ran these checks, a different owner or reviewer must approve them.</small>}</> : <p className="coach-inline-note">Waiting for a workspace owner or reviewer.</p>}
        </section>

        <section className="persona-release-step is-publish" aria-labelledby="publish-title">
          <header><div><span>5</span><div><h4 id="publish-title">Publish this assistant version</h4><p>Publishing seals this exact preview, candidate, evaluation, phrase review, and approval as one version.</p></div></div><StepState complete={publishReady} label={publishReady ? 'Ready' : 'Blocked'} /></header>
          {readiness?.blockers.length ? <ul className="persona-release-blockers">{readiness.blockers.map((blocker) => <li key={blocker}>{blocker}</li>)}</ul> : null}
          {persona.assignments.length > 0 && <p className="coach-inline-note">Publishing updates future participant messages in {persona.assignments.length} assigned cohort{persona.assignments.length === 1 ? '' : 's'}. You will confirm this impact before it changes.</p>}
          <div className="persona-release-actions"><Button onClick={() => evidence && onPublish(evidence)} disabled={!publishReady || parentBusy || action !== null}>{publishPending ? 'Publishing…' : persona.published_version ? 'Publish next version' : 'Publish first version'}</Button></div>
          {!readiness?.permissions.publish && <p className="coach-inline-note">A workspace owner or reviewer must publish the approved version.</p>}
          {readiness?.candidate && <details className="persona-release-details"><summary>Release evidence</summary><dl className="persona-release-evidence"><div><dt>Draft revision</dt><dd>{readiness.candidate.draft_revision}</dd></div><div><dt>Candidate</dt><dd>{shortDigest(readiness.candidate.manifest_digest)}</dd></div><div><dt>Evaluation</dt><dd>{shortDigest(readiness.evaluation_run?.run_digest)}</dd></div><div><dt>Approval</dt><dd>{shortDigest(readiness.approval?.approval_digest)}</dd></div></dl></details>}
        </section>
      </>}
    </article>
  )
}

function GuardrailCase({ evaluationCase }: { evaluationCase: AdminPersonaEvaluationCase }) {
  return <details className="persona-release-case"><summary><span>{evaluationCase.name}</span><small>{evaluationCase.required ? 'Required' : evaluationCase.active ? 'Included' : 'Retired'}</small></summary><div><p>{evaluationCase.prompt}</p><ul>{evaluationCase.assertions.map((assertion, index) => <li key={`${assertion.type}-${index}`}>{assertionLabel(assertion)}</li>)}</ul></div></details>
}

function RunResult({ run }: { run: AdminPersonaEvaluationRun }) {
  return <section className={`persona-release-run is-${run.status}`} aria-label="Automated guardrail check results"><header><div><strong>{run.status === 'passed' ? 'All automated guardrails passed' : run.status === 'failed' ? 'Automated checks need attention' : run.status === 'error' ? 'Checks could not finish' : 'Checks are running'}</strong><small>{run.requested_by ? `Run by ${run.requested_by.full_name}` : 'Workspace evaluation'} · {formatDate(run.completed_at ?? run.started_at)}</small></div><StepState complete={run.passed} label={run.status} /></header>{run.results?.map((result) => <details key={result.id} className="persona-release-result" open={result.status !== 'passed'}><summary><span>{result.case.name}</span><StepState complete={result.status === 'passed' && !result.fallback_only} label={result.fallback_only ? 'Fallback output' : result.status} /></summary><div><div><small>Test prompt</small><p>{result.case.prompt}</p></div><div><small>Checked output</small><blockquote>{result.output}</blockquote></div><ul>{result.assertion_results.map((assertion, index) => <li key={`${assertion.type}-${index}`} className={assertion.passed ? 'is-passed' : 'is-failed'}>{assertion.passed ? 'Passed' : 'Failed'}: {assertionLabel(result.case.assertions[index] ?? { type: assertion.type })}</li>)}</ul></div></details>)}</section>
}

function AudienceSnapshot({ readiness }: { readiness: AdminPersonaReleaseReadiness }) {
  const audience = readiness.candidate?.audience_snapshot
  if (!audience) return null
  return <div className="persona-release-audience" role="note"><strong>Audience sealed with this release</strong><p>{audience.audience}</p><dl><div><dt>Participant term</dt><dd>{audience.client_term}</dd></div><div><dt>Locale context</dt><dd>{audience.culture.locale_label || 'No locale label'}</dd></div><div><dt>Community context</dt><dd>{audience.culture.context || 'No added context'}</dd></div>{audience.culture.local_realities.length > 0 && <div><dt>Local realities</dt><dd>{audience.culture.local_realities.join('; ')}</dd></div>}{audience.culture.references.length > 0 && <div><dt>Reviewed references</dt><dd>{audience.culture.references.join('; ')}</dd></div>}</dl></div>
}

function PreviewSummary({ preview, current }: { preview: AdminPersonaPreview; current: boolean }) {
  return <section className={`coach-preview-result is-${preview.status}`} aria-label="Exact draft preview"><header><div><strong>{preview.status === 'ready' ? 'Behavioral sample ready' : preview.status === 'safety_only' ? 'Safety response only' : 'Behavioral preview unavailable'}</strong><small>Draft revision {preview.draft_revision} · {humanize(preview.source)}</small></div><StepState complete={current} label={current ? 'Current' : 'Not publishable'} /></header><p>{preview.notice}</p>{preview.sample_prompt && <div><small>Sample question</small><p>{preview.sample_prompt}</p></div>}{preview.sample_reply && <blockquote>{preview.sample_reply}</blockquote>}{!preview.sample_reply && preview.status === 'unavailable' && <p className="coach-inline-note">No generated answer is shown. Publishing stays locked until a successful behavioral preview checks this exact draft.</p>}<details><summary>Compiled instructions for this revision</summary><pre>{preview.rendered_instructions}</pre></details><small>Guardrails applied: {preview.guardrails_applied ? 'Yes' : 'No'} · Generated {formatDate(preview.generated_at)}</small></section>
}

function StepState({ complete, label }: { complete: boolean; label: string }) {
  return <span className={`persona-release-state ${complete ? 'is-complete' : ''}`}>{label}</span>
}

function releaseEvidence(readiness: AdminPersonaReleaseReadiness | null): PersonaPublishEvidence | null {
  const candidateDigest = readiness?.candidate?.manifest_digest
  const runDigest = readiness?.evaluation_run?.run_digest
  const approvalDigest = readiness?.approval?.approval_digest
  if (!candidateDigest || !runDigest || !approvalDigest) return null
  return { release_candidate_digest: candidateDigest, evaluation_run_digest: runDigest, evaluation_approval_digest: approvalDigest }
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
