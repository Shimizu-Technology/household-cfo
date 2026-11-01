import { useEffect, useRef, useState } from 'react'
import { fetchAdminPersona, fetchAdminPersonaEvaluationRun, fetchAdminPersonaReleaseReadiness, previewAdminPersona, publishAdminPersona, reviewAdminPersonaAudience, reviewAdminPersonaEvaluation, runAdminPersonaEvaluation, type AdminPersonaAssignableCohort, type AdminPersonaDetail, type AdminPersonaReleaseReadiness } from '../api'
import { publishCoachGroup, reviewCoachGroup, type GroupReview } from '../lib/coachGoLive'
import { Button } from './Button'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

const samples = ['I want to spend $100 this weekend. How can I decide?', 'I had a hard week and spent more than I planned. What can I do next?']
export function CoachGoLive({ persona, cohorts, lifecycle, onPersonaChange }: { persona: AdminPersonaDetail; cohorts: AdminPersonaAssignableCohort[]; lifecycle: CoachWorkspaceMutationLifecycle; onPersonaChange: (persona: AdminPersonaDetail) => void }) {
  const [answers, setAnswers] = useState<Array<{question: string; answer: string}>>([])
  const [readiness, setReadiness] = useState<AdminPersonaReleaseReadiness | null>(null)
  const [reviewed, setReviewed] = useState(false)
  const [phrases, setPhrases] = useState<string[]>([])
  const [groupIds, setGroupIds] = useState<number[]>(cohorts.filter((item) => item.assignable).map((item) => item.id))
  const [groups, setGroups] = useState<GroupReview[]>([])
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
    setBusy(true); setError(null); setReviewed(false); setReadiness(null); setPhrases([]); setAnswers([])
    try {
      const results = []
      if (persona.has_unpublished_changes !== false) {
        for (const question of samples) {
          if (!current()) return
          setStatus('Preparing an example answer…')
          const result = await previewAdminPersona(persona.id, persona.draft_revision, question)
          if (!current()) return
          if (!result.behavioral_preview_evidence?.valid) throw new Error('This preview could not be verified. Try again before publishing.')
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
        const ready = await fetchAdminPersonaReleaseReadiness(persona.id)
        if (!current()) return
        setReadiness(ready)
      }
      setStatus('Preparing your group review…')
      const reviews = []
      for (const group of cohorts.filter((item) => groupIds.includes(item.id))) {
        if (!current()) return
        reviews.push(await reviewCoachGroup(group))
      }
      if (!current()) return
      setGroups(reviews)
      setStatus('Review the answers, phrases and groups below. Your participants still have their current settings.')
    } catch (caught) { if (current()) setError(caught instanceof Error ? caught.message : 'The preview could not finish. Try again.') }
    finally { if (mounted.current) setBusy(false); lifecycle.finish(ticket) }
  }

  async function goLive() {
    if (busy || lifecycle.pending || !reviewed || groups.length === 0) return
    const ticket = lifecycle.begin()
    const current = () => mounted.current && lifecycle.isCurrent(ticket)
    setBusy(true); setError(null)
    try {
      let published = publishedPersona.current ?? persona
      if (!publishedPersona.current && persona.has_unpublished_changes !== false) {
        if (!readiness?.candidate || !readiness.evaluation_run?.run_digest || !readiness.behavioral_preview_evidence?.valid) throw new Error('Preview the latest saved voice first.')
        for (const phrase of readiness.phrase_audience_reviews) {
          if (!phrases.includes(phrase.artifact_id)) throw new Error('Review each phrase before going live.')
          if (!current()) return
          if (phrase.review_state !== 'approved') await reviewAdminPersonaAudience(persona.id, { candidate_digest: readiness.candidate.manifest_digest, artifact_id: phrase.artifact_id, artifact_fingerprint: phrase.artifact_fingerprint, decision: 'approved' })
        }
        if (!current()) return
        if (!readiness.approval?.valid) await reviewAdminPersonaEvaluation(persona.id, readiness.evaluation_run.id, 'approved', readiness.evaluation_run.run_digest)
        if (!current()) return
        const ready = await fetchAdminPersonaReleaseReadiness(persona.id)
        if (!current()) return
        if (!ready.ready || !ready.candidate || !ready.approval?.valid || !ready.evaluation_run?.run_digest || !ready.behavioral_preview_evidence?.valid) throw new Error('The voice or review changed. Preview again before publishing.')
        const saved = await fetchAdminPersona(persona.id)
        if (!current()) return
        if (saved.draft_revision !== persona.draft_revision || saved.published_version?.id !== persona.published_version?.id || ready.candidate.manifest_digest !== readiness.candidate.manifest_digest || ready.behavioral_preview_evidence.digest !== readiness.behavioral_preview_evidence.digest) throw new Error('Your assistant changed. Review its latest preview before going live.')
        published = (await publishAdminPersona(persona.id, { draft_revision: persona.draft_revision!, preview_digest: saved.preview!.digest, expected_published_version_id: persona.published_version?.id ?? null, release_candidate_digest: ready.candidate.manifest_digest, evaluation_run_digest: ready.evaluation_run.run_digest, evaluation_approval_digest: ready.approval.approval_digest, behavioral_preview_digest: ready.behavioral_preview_evidence.digest })).persona
        if (!current()) return
        publishedPersona.current = published
      }
      if (!published.published_version) throw new Error('Publish the assistant before updating a group.')
      for (const group of groups) {
        if (!current()) return
        if (completedGroups.current.has(group.group.id)) continue
        setStatus(`Updating ${group.group.name}…`)
        await publishCoachGroup(group, published.id, published.published_version.id, requestId.current, current)
        if (!current()) return
        completedGroups.current.add(group.group.id)
      }
      setStatus(`Live for ${groups.map((item) => item.group.name).join(', ')}. Participants will hear your assistant and see the published tools and appearance.`)
      setReviewed(false)
      onPersonaChange(published)
    } catch (caught) {
      if (current()) setError(`${caught instanceof Error ? caught.message : 'Publishing could not finish.'}${publishedPersona.current ? ' Your assistant is published. Completed groups stay live; retry continues the remaining groups.' : ''}`)
    } finally { if (mounted.current) setBusy(false); lifecycle.finish(ticket) }
  }
  const canPublish = Boolean(persona.permissions.publish && reviewed && groups.length > 0 && (persona.has_unpublished_changes === false || readiness) && (readiness?.phrase_audience_reviews.every((item) => phrases.includes(item.artifact_id)) ?? true))
  return <article className="panel coach-go-live" aria-busy={busy}>
    <h3>Hear your assistant, then go live</h3><p>Try two everyday questions with fictional details. Review the answers before your people receive any changes.</p>
    <fieldset disabled={busy}><legend>Who will receive these changes?</legend>{cohorts.filter((item) => item.assignable).map((group) => <label key={group.id}><input type="checkbox" checked={groupIds.includes(group.id)} onChange={(event) => { setGroupIds((ids) => event.target.checked ? [...ids, group.id] : ids.filter((id) => id !== group.id)); setGroups([]); setReviewed(false) }} />{group.name}</label>)}{cohorts.length === 0 && <p>Create a group in People → Group invitations &amp; access first.</p>}</fieldset>
    <Button disabled={busy || lifecycle.pending || groupIds.length === 0 || !persona.permissions.publish} onClick={() => void preview()}>{busy ? 'Preparing…' : persona.has_unpublished_changes === false ? 'Review group changes' : 'Preview answers and check safety'}</Button>
    {status && <p role="status">{status}</p>}{error && <p role="alert">{error}</p>}
    <div className="coach-answer-comparison">{answers.map((item) => <section key={item.question}><h4>{item.question}</h4><p>{item.answer}</p></section>)}</div>
    {groups.length > 0 && <section><h4>Review before going live</h4><p>{persona.draft?.identity.assistant_name ?? persona.name} · {groups.map((item) => `${item.group.name} (${item.participantIds.length} people)`).join(', ')}</p><p>The published voice, appearance and tools will go to these groups together.</p>
      {readiness?.phrase_audience_reviews.map((item) => <label className="coach-phrase-approval" key={item.artifact_id}><input type="checkbox" checked={phrases.includes(item.artifact_id)} disabled={busy} onChange={(event) => setPhrases((ids) => event.target.checked ? [...ids,item.artifact_id] : ids.filter((id) => id !== item.artifact_id))} /><span><strong>{item.phrase.text}</strong> — {item.phrase.meaning}<small>Use: {item.phrase.allowed_contexts.join(', ')} · {item.phrase.frequency}. {item.phrase.caution}</small></span></label>)}
      <label><input type="checkbox" checked={reviewed} disabled={busy} onChange={(event) => setReviewed(event.target.checked)} />I reviewed the answers and safety checks, and approve these changes for these groups.</label>
      <Button disabled={busy || !canPublish} onClick={() => void goLive()}>Go live for these groups</Button>
      <details><summary>Advanced / history</summary><p>Safety checks: {readiness?.evaluation_run?.passed ? 'Passed' : persona.has_unpublished_changes === false ? 'Published assistant retained' : 'Not ready'}. Human and phrase approvals are recorded when you go live. Earlier versions and controlled group updates stay available in Your assistant → Advanced / history.</p><pre>{JSON.stringify(readiness?.evaluation_run ?? {}, null, 2)}</pre></details>
    </section>}
  </article>
}
