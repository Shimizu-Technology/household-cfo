import { useEffect, useEffectEvent, useRef, useState } from 'react'
import { fetchAdminPersona, fetchAdminPersonaEvaluationRun, fetchAdminPersonaReleaseReadiness, previewAdminPersona, publishAdminPersona, reviewAdminPersonaAudience, reviewAdminPersonaEvaluation, runAdminPersonaEvaluation, type AdminPersonaAssignableCohort, type AdminPersonaDetail, type AdminPersonaReleaseReadiness, type AdminPersonaEvaluationResult, type AdminPersonaBehavioralPreviewEvidence } from '../api'
import { publishCoachGroup, reviewCoachGroup, type GroupReview } from '../lib/coachGoLive'
import { reviewCoachSettings, publishCoachSettings, type CoachSettingsReview, type PublishedCoachSettings } from '../lib/coachSettingsReview'
import { BrandWelcomePreview } from './CoachProgramSettings'
import { Button } from './Button'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

const samples = ['I want to spend $100 this weekend. How can I decide?', 'I had a hard week and spent more than I planned. What can I do next?']
const previewUnavailableNotice = "The preview didn't come through. Try again in a minute."
function previewFailureNotice(error: unknown): string {
  const status = error && typeof error === 'object' && 'status' in error ? error.status : null
  if (status === 401 || status === 403) return 'You don’t have permission to preview this assistant. Ask your workspace owner for access.'
  if (status === 409) return 'Your voice changed. Reopen it and preview the latest saved version.'
  if (status === 422) return 'The voice needs attention. Open it to review the highlighted fields.'
  if ((error instanceof Error && error.name === 'ApiDeadlineError') || status === 408 || status === 429 || (typeof status === 'number' && status >= 500)) return previewUnavailableNotice
  return 'The preview could not finish. Reopen your assistant and try again.'
}
export function CoachGoLive({ persona, cohorts, lifecycle, onPersonaChange, onEditVoice, autoPreview = false }: { persona: AdminPersonaDetail; cohorts: AdminPersonaAssignableCohort[]; lifecycle: CoachWorkspaceMutationLifecycle; onPersonaChange: (persona: AdminPersonaDetail) => void; onEditVoice?: () => void; autoPreview?: boolean }) {
  const [checks, setChecks] = useState<AdminPersonaEvaluationResult[]>([])
  const [answers, setAnswers] = useState<Array<{question: string; answer: string}>>([])
  const [reviewedPersona, setReviewedPersona] = useState<AdminPersonaDetail | null>(null)
  const [readiness, setReadiness] = useState<AdminPersonaReleaseReadiness | null>(null)
  const [groupIds, setGroupIds] = useState<number[]>(cohorts.filter((item) => item.assignable).map((item) => item.id))
  const [groups, setGroups] = useState<GroupReview[]>([])
  const [settings, setSettings] = useState<CoachSettingsReview | null>(null)
  const publishedSettings = useRef<PublishedCoachSettings | null>(null)
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState('')
  const [error, setError] = useState<string | null>(null)
  const requestId = useRef(crypto.randomUUID())
  const mounted = useRef(true)
  const publishedPersona = useRef<AdminPersonaDetail | null>(null)
  const completedGroups = useRef(new Set<number>())
  useEffect(() => { mounted.current = true; return () => { mounted.current = false } }, [])

  async function preview() {
    if (busy || lifecycle.pending || persona.draft_revision == null) return
    const ticket = lifecycle.begin()
    const current = () => mounted.current && lifecycle.isCurrent(ticket)
    setBusy(true); setError(null); setReadiness(null); setChecks([]); setAnswers([]); setSettings(null); setGroups([]); publishedSettings.current = null; publishedPersona.current = null; completedGroups.current.clear(); setReviewedPersona(null); requestId.current = crypto.randomUUID()
    try {
      const source = await fetchAdminPersona(persona.id)
      if (!current()) return
      setReviewedPersona(source)
      const results = []
      let lastEvidence: AdminPersonaBehavioralPreviewEvidence | null = null
      if (source.has_unpublished_changes !== false) {
        for (const question of samples) {
          if (!current()) return
          setStatus('Preparing an example answer…')
          const result = await previewAdminPersona(source.id, source.draft_revision!, question).catch((error: unknown) => { throw new Error(previewFailureNotice(error)) })
          if (!current()) return
          if (!result.behavioral_preview_evidence?.valid) throw new Error(previewUnavailableNotice)
          if (lastEvidence && lastEvidence.candidate_digest !== result.behavioral_preview_evidence.candidate_digest) throw new Error('Your voice changed. Preview again before reviewing it.')
          lastEvidence = result.behavioral_preview_evidence
          results.push({ question, answer: result.behavioral_preview_evidence.output })
          setAnswers([...results])
        }
        setStatus('Checking safety…')
        let run = (await runAdminPersonaEvaluation(persona.id, `${requestId.current}:checks`)).evaluation_run
        if (!current()) return
        for (let attempt = 0; ['pending', 'running'].includes(run.status) && attempt < 60; attempt += 1) {
          await new Promise((resolve) => setTimeout(resolve, 1750))
          if (!current()) return
          run = await fetchAdminPersonaEvaluationRun(persona.id, run.id)
        }
        if (!current()) return
        if (!run.passed) throw new Error('Safety checks need attention. Review the results in Advanced / history before publishing.')
        const detail = run.results ? run : await fetchAdminPersonaEvaluationRun(persona.id, run.id)
        if (!current()) return
        setChecks(detail.results ?? [])
        const ready = await fetchAdminPersonaReleaseReadiness(persona.id)
        if (!current()) return
        const saved = await fetchAdminPersona(source.id)
        if (!current()) return
        if (saved.draft_revision !== source.draft_revision || saved.published_version?.id !== source.published_version?.id || ready.candidate?.draft_revision !== source.draft_revision || ready.candidate?.manifest_digest !== run.candidate_digest || ready.evaluation_run?.id !== run.id || ready.evaluation_run?.run_digest !== run.run_digest || ready.behavioral_preview_evidence?.digest !== lastEvidence?.digest || ready.candidate?.manifest_digest !== lastEvidence?.candidate_digest) throw new Error('Your voice or safety checks changed. Preview again before reviewing it.')
        setReadiness(ready)
      }
      setStatus('Preparing your group review…')
      const settingsReview = await reviewCoachSettings(groupIds, current)
      if (!current()) return
      const reviews = []
      for (const group of cohorts.filter((item) => groupIds.includes(item.id))) {
        if (!current()) return
        reviews.push(await reviewCoachGroup(group))
      }
      if (!current()) return
      setSettings(settingsReview)
      setGroups(reviews)
      setStatus(source.has_unpublished_changes === false ? 'Review the appearance, tools and groups below. Your participants still have their current settings.' : 'Review the answers, phrases and groups below. Your participants still have their current settings.')
    } catch (caught) { if (current()) { setStatus(''); setError(caught instanceof Error ? caught.message : 'The preview could not finish. Try again.') } }
    finally { if (mounted.current) setBusy(false); lifecycle.finish(ticket) }
  }

  const startedAutomatically = useRef(false)
  const startPreview = useEffectEvent(() => void preview())
  useEffect(() => {
    if ((!autoPreview && persona.has_unpublished_changes !== false) || groupIds.length === 0 || lifecycle.pending || startedAutomatically.current) return
    startedAutomatically.current = true
    startPreview()
  }, [autoPreview, lifecycle.pending, persona.has_unpublished_changes, groupIds.length])

  async function goLive() {
    if (busy || lifecycle.pending || groups.length === 0) return
    const ticket = lifecycle.begin()
    const current = () => mounted.current && lifecycle.isCurrent(ticket)
    setBusy(true); setError(null)
    try {
      const approved = reviewedPersona
      if (!approved) throw new Error('Review your assistant first.')
      if (!settings) throw new Error('Review the saved appearance and tools first.')
      const reviewedSaved = await fetchAdminPersona(approved.id)
      if (!current()) return
      if (reviewedSaved.draft_revision !== approved.draft_revision || reviewedSaved.published_version?.id !== approved.published_version?.id) throw new Error('Your assistant changed. Review its latest preview before going live.')
      if (approved.has_unpublished_changes !== false) {
        if (!reviewedSaved.preview?.digest) throw new Error('Your assistant changed. Preview again before publishing.')
        const latest = await fetchAdminPersonaReleaseReadiness(approved.id)
        if (!current()) return
        if (!readiness?.candidate || latest.candidate?.draft_revision !== approved.draft_revision || latest.candidate?.manifest_digest !== readiness.candidate.manifest_digest || latest.evaluation_run?.id !== readiness.evaluation_run?.id || latest.evaluation_run?.run_digest !== readiness.evaluation_run?.run_digest || latest.behavioral_preview_evidence?.digest !== readiness.behavioral_preview_evidence?.digest) throw new Error('Your voice or safety checks changed. Preview again before approving them.')
      }
      publishedSettings.current ??= await publishCoachSettings(settings, requestId.current, current)
      if (!current()) return
      let published = publishedPersona.current ?? approved
      if (!publishedPersona.current && approved.has_unpublished_changes !== false) {
        if (!readiness?.candidate || !readiness.evaluation_run?.run_digest || !readiness.behavioral_preview_evidence?.valid) throw new Error('Preview the latest saved voice first.')
        for (const phrase of readiness.phrase_audience_reviews) {
          if (!current()) return
          if (phrase.review_state !== 'approved') await reviewAdminPersonaAudience(approved.id, { candidate_digest: readiness.candidate.manifest_digest, artifact_id: phrase.artifact_id, artifact_fingerprint: phrase.artifact_fingerprint, decision: 'approved' })
        }
        if (!current()) return
        if (!readiness.approval?.valid) await reviewAdminPersonaEvaluation(approved.id, readiness.evaluation_run.id, 'approved', readiness.evaluation_run.run_digest)
        if (!current()) return
        const ready = await fetchAdminPersonaReleaseReadiness(approved.id)
        if (!current()) return
        if (!ready.ready || !ready.candidate || !ready.approval?.valid || !ready.evaluation_run?.run_digest || !ready.behavioral_preview_evidence?.valid) throw new Error('The voice or review changed. Preview again before publishing.')
        const saved = await fetchAdminPersona(approved.id)
        if (!current()) return
        if (saved.draft_revision !== approved.draft_revision || saved.published_version?.id !== approved.published_version?.id || ready.candidate.manifest_digest !== readiness.candidate.manifest_digest || ready.evaluation_run.id !== readiness.evaluation_run?.id || ready.evaluation_run.run_digest !== readiness.evaluation_run?.run_digest || ready.behavioral_preview_evidence.digest !== readiness.behavioral_preview_evidence.digest) throw new Error('Your assistant changed. Review its latest preview before going live.')
        if (!saved.preview?.digest) throw new Error('Your assistant changed. Preview again before publishing.')
        published = (await publishAdminPersona(approved.id, { draft_revision: approved.draft_revision!, preview_digest: saved.preview.digest, expected_published_version_id: approved.published_version?.id ?? null, release_candidate_digest: ready.candidate.manifest_digest, evaluation_run_digest: ready.evaluation_run.run_digest, evaluation_approval_digest: ready.approval.approval_digest, behavioral_preview_digest: ready.behavioral_preview_evidence.digest })).persona
        if (!current()) return
        publishedPersona.current = published
      }
      if (!published.published_version) throw new Error('Publish the assistant before updating a group.')
      for (const group of groups) {
        if (!current()) return
        if (completedGroups.current.has(group.group.id)) continue
        setStatus(`Updating ${group.group.name}…`)
        await publishCoachGroup(group, published.id, published.published_version.id, requestId.current, current, publishedSettings.current)
        if (!current()) return
        completedGroups.current.add(group.group.id)
      }
      setStatus(`Live for ${groups.map((item) => item.group.name).join(', ')}. Participants will hear your assistant and see the published tools and appearance.`)
      setGroups([]); setSettings(null)
      startedAutomatically.current = true
      onPersonaChange(published)
    } catch (caught) {
      if (current()) {
        setGroups([]); setSettings(null); setReviewedPersona(null)
        setError(`${caught instanceof Error ? caught.message : 'Publishing could not finish.'}${publishedPersona.current ? ' Your assistant is published. Completed groups stay live. Reopen Go live to review any remaining group, or finish its saved update in Advanced / history.' : ' Review again before retrying.'}`)
      }
    } finally { if (mounted.current) setBusy(false); lifecycle.finish(ticket) }
  }
  const canPublish = Boolean(persona.permissions.publish && settings && groups.length > 0 && (reviewedPersona?.has_unpublished_changes === false || readiness))
  const voiceChanges = (reviewedPersona ?? persona).has_unpublished_changes !== false
  return <article className="panel coach-go-live" aria-busy={busy}>
    <h3>{voiceChanges ? 'Hear your assistant, then go live' : 'Review changes, then go live'}</h3><p>{voiceChanges ? 'Try two everyday questions with fictional details. Review the answers before your people receive any changes.' : 'Your assistant’s voice stays the same. Review the appearance, tools and groups below.'}</p>
    {!persona.published_version && <><p>Preview and approve your assistant’s voice before your saved tools can go live. You can use the standard voice or edit it first.</p>{onEditVoice && <Button variant="secondary" disabled={busy || lifecycle.pending} onClick={onEditVoice}>Edit assistant’s voice</Button>}</>}
    <fieldset disabled={busy}><legend>Who will receive these changes?</legend>{cohorts.filter((item) => item.assignable).map((group) => <label key={group.id}><input type="checkbox" checked={groupIds.includes(group.id)} onChange={(event) => { setGroupIds((ids) => event.target.checked ? [...ids, group.id] : ids.filter((id) => id !== group.id)); setGroups([]) }} />{group.name}</label>)}{cohorts.length === 0 && <p>Create a group in People → Group invitations &amp; access first.</p>}</fieldset>
    {groups.length === 0 && <Button disabled={busy || lifecycle.pending || groupIds.length === 0 || !persona.permissions.publish} onClick={() => void preview()}>{busy ? 'Preparing…' : persona.has_unpublished_changes === false ? 'Review changes' : 'Preview answers'}</Button>}
    {status && <p role="status">{status}</p>}{error && <p role="alert">{error}</p>}
    <div className="coach-answer-comparison">{answers.map((item) => <section key={item.question}><h4>{item.question}</h4><p>{item.answer}</p></section>)}</div>
    {groups.length > 0 && <section><h4>Review before going live</h4><p>{reviewedPersona?.draft?.identity.assistant_name ?? reviewedPersona?.name} · {groups.map((item) => `${item.group.name} (${item.participantIds.length} ${item.participantIds.length === 1 ? 'person' : 'people'})`).join(', ')}</p><p>These groups will receive this assistant, appearance and tools together.</p>
      {settings && <><BrandWelcomePreview config={settings.brand.preview.brand} />{settings.tools.map((item) => <section key={item.configuration.cohort.id}><h4>Tools for {item.configuration.cohort.name}</h4>{item.preview.upgrade_notice && <p>{item.preview.upgrade_notice}</p>}<p>{item.configuration.draft.experience_mode === 'savings_challenge' ? '90-day Savings Challenge' : 'Household CFO'}</p><p>{item.preview.modules.filter((module) => module.enabled).map((module) => module.label).join(' · ')}</p><p>Hidden: {item.preview.modules.filter((module) => !module.enabled).map((module) => module.label).join(', ') || 'None'}</p></section>)}</>}
      {readiness?.candidate?.audience_snapshot && <p>For: {readiness.candidate.audience_snapshot.audience}<br />Community context: {readiness.candidate.audience_snapshot.culture.context}</p>}
      {checks.length > 0 && <details><summary>Safety checks passed ({checks.length})</summary><ul>{checks.map((item) => <li key={item.id}>{item.case.name}: {item.status}</li>)}</ul></details>}
      {readiness?.phrase_audience_reviews.map((item) => <div className="coach-phrase-approval" key={item.artifact_id}><strong>{item.phrase.text}</strong> — {item.phrase.meaning}<small>Use: {item.phrase.allowed_contexts.map((context) => context.replaceAll('_', ' ')).join(', ')} · {item.phrase.frequency}. {item.phrase.caution}</small></div>)}
      <p id="coach-go-live-consent">{voiceChanges ? 'By choosing Approve and go live, you approve the answers, phrases, safety checks and group changes shown above.' : 'By choosing Approve and go live, you approve the appearance, tools and group changes shown above.'}</p>
      <Button aria-describedby="coach-go-live-consent" disabled={busy || !canPublish} onClick={() => void goLive()}>Approve and go live</Button>
    </section>}
  </article>
}
