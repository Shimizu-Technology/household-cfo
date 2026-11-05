import { useEffect, useEffectEvent, useRef, useState } from 'react'
import { resolveCoachLaunch, fetchAdminPersona, fetchAdminPersonaEvaluationRun, fetchAdminPersonaReleaseReadiness, previewAdminPersona, runAdminPersonaEvaluation, type AdminPersonaAssignableCohort, type AdminPersonaDetail, type AdminPersonaReleaseReadiness, type AdminPersonaEvaluationResult, type AdminPersonaBehavioralPreviewEvidence } from '../api'
import { reviewCoachGroup, type GroupReview } from '../lib/coachGoLive'
import { reviewCoachSettings, toolChanges, type CoachSettingsReview } from '../lib/coachSettingsReview'
import { prepareCoachLaunch, finishCoachLaunch, launchStorageKey, readPendingLaunch, type PendingCoachLaunch } from '../lib/coachLaunch'
import { useAuthContext } from '../contexts/authContextValue'
import { participantSectionsForModules, partitionParticipantSections, participantSectionLabel } from '../lib/participantNavigation'
import { BrandWelcomePreview } from './CoachProgramSettings'
import { Button } from './Button'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

const samples = ['Should I buy a $100 treat on my credit card? I don’t have the money right now.', 'I had a hard week and spent more than I planned. What can I do next?']
const previewUnavailableNotice = "The preview didn't come through. Try again in a minute."
const previewRejectionNotices = new Set([
  'The sample answer was outside the response length you chose, even after one rewrite. Adjust the response length in Teaching, then preview again.',
  'The sample answer did not use the response format you chose. Check the format in Teaching, then preview again.',
  'The sample answer did not pass the reply checks. Review the response length, format, and safety guidance in Teaching, then preview again.',
])
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
  const [answers, setAnswers] = useState<Array<{question: string; answer: string; phraseNotice?: string | null}>>([])
  const [reviewedPersona, setReviewedPersona] = useState<AdminPersonaDetail | null>(null)
  const [readiness, setReadiness] = useState<AdminPersonaReleaseReadiness | null>(null)
  const [groupIds, setGroupIds] = useState<number[]>(cohorts.filter((item) => item.assignable).map((item) => item.id))
  const [groups, setGroups] = useState<GroupReview[]>([])
  const [settings, setSettings] = useState<CoachSettingsReview | null>(null)
  const { currentUser } = useAuthContext()
  const storageKey = launchStorageKey(currentUser?.id, persona.id)
  const [pendingLaunch, setPendingLaunch] = useState<PendingCoachLaunch | null>(() => readPendingLaunch(storageKey))
  const [live, setLive] = useState(false)
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState('')
  const [error, setError] = useState<string | null>(null)
  const requestId = useRef(crypto.randomUUID())
  const mounted = useRef(true)
  useEffect(() => { mounted.current = true; return () => { mounted.current = false } }, [])

  async function preview() {
    if (busy || lifecycle.pending || pendingLaunch || persona.draft_revision == null) return
    const ticket = lifecycle.begin()
    const current = () => mounted.current && lifecycle.isCurrent(ticket)
    setBusy(true); setError(null); setReadiness(null); setChecks([]); setAnswers([]); setSettings(null); setGroups([]); setReviewedPersona(null); requestId.current = crypto.randomUUID()
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
          if (!result.behavioral_preview_evidence?.valid) throw new Error(result.preview?.notice && previewRejectionNotices.has(result.preview.notice) ? result.preview.notice : previewUnavailableNotice)
          if (lastEvidence && lastEvidence.candidate_digest !== result.behavioral_preview_evidence.candidate_digest) throw new Error('Your voice changed. Preview again before reviewing it.')
          lastEvidence = result.behavioral_preview_evidence
          results.push({ question, answer: result.behavioral_preview_evidence.output, phraseNotice: result.preview?.phrase_notice })
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
        if (ready.phrase_audience_reviews?.some(phrase => phrase.review_state === 'rejected')) throw new Error('A phrase was rejected for this audience. Review it before going live.')
        const reviewRule = ready.blockers?.find(message => message.includes('different workspace owner or reviewer'))
        if (reviewRule) throw new Error(reviewRule)
        setReviewedPersona(saved)
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
    if (pendingLaunch || live || (!autoPreview && persona.has_unpublished_changes !== false) || groupIds.length === 0 || lifecycle.pending || startedAutomatically.current) return
    startedAutomatically.current = true
    startPreview()
  }, [autoPreview, lifecycle.pending, persona.has_unpublished_changes, groupIds.length, pendingLaunch, live])

  async function goLive() {
    if (busy || lifecycle.pending) return
    const ticket = lifecycle.begin()
    const current = () => mounted.current && lifecycle.isCurrent(ticket)
    setBusy(true); setError(null)
    let savedForRecovery = Boolean(pendingLaunch)
    try {
      if (!pendingLaunch && (!reviewedPersona || !settings || groups.length === 0)) throw new Error('Review your assistant first.')
      const pending = pendingLaunch ?? prepareCoachLaunch(reviewedPersona!, readiness, settings!, groups)
      // Persist before sending. A lost response can always be retried with the
      // same receipt key, even after closing this tab.
      localStorage.setItem(storageKey, JSON.stringify(pending))
      savedForRecovery = true
      setPendingLaunch(pending)
      setStatus(`Saving your assistant and updating ${pending.review.groups.map(item => item.name).join(', ')}… You can reopen Go live if you leave this page.`)
      const result = await finishCoachLaunch(pending)
      if (!current()) return
      showLive(result)
    } catch (caught) {
      if (current()) {
        const code = caught && typeof caught === 'object' && 'status' in caught ? caught.status : null
        if (!savedForRecovery) {
          setStatus(''); setError('Your browser could not save the update for recovery. Allow storage for this site, then try again.')
        } else if (caught && typeof caught === 'object' && 'payload' in caught && caught.payload && typeof caught.payload === 'object' && 'rejected' in caught.payload && caught.payload.rejected === true) {
          setStatus(''); setError(`${caught instanceof Error ? caught.message : 'This update was not saved.'} Choose Check this update before reviewing again.`)
        } else if (code === 409 || code === 422) {
          setStatus(''); setError(`${caught instanceof Error ? caught.message : 'This update was refused.'} Choose Check this update before reviewing again.`)
        } else if (code === 401 || code === 403) {
          setStatus(''); setError(pendingLaunch
            ? 'We could not confirm whether your update went live. Sign in with access to this program, then choose Check this update.'
            : 'This update was refused. Sign in with access to this program, then choose Check this update before reviewing again.')
        } else {
          setStatus(''); setError('We could not confirm the update. Choose Finish going live to retry, or Check this update to find out what happened and start again safely.')
        }
      }
    } finally { if (mounted.current) setBusy(false); lifecycle.finish(ticket) }
  }
  function showLive(result: Awaited<ReturnType<typeof finishCoachLaunch>>) {
    localStorage.removeItem(storageKey)
    setPendingLaunch(null); setLive(true)
    setStatus(`Live for ${result.launch.groups.map(item => item.name).join(', ')}. Participants will hear your assistant and see the published tools and appearance.${result.launch.groups.filter(item => item.challenge_closed).map(item => ` ${item.name}: the program team still needs to open the savings challenge. Participants will see “Your savings challenge opens soon” until then.`).join('')}`)
    setGroups([]); setSettings(null); setReviewedPersona(result.persona)
    startedAutomatically.current = true
    onPersonaChange(result.persona)
  }

  async function checkUpdate() {
    if (!pendingLaunch || busy || lifecycle.pending) return
    const ticket = lifecycle.begin()
    const current = () => mounted.current && lifecycle.isCurrent(ticket)
    setBusy(true); setError(null); setStatus('Checking your earlier update…')
    try {
      const result = await resolveCoachLaunch(pendingLaunch.review, pendingLaunch.key)
      if (!current()) return
      if (result.status === 'live') {
        showLive(result)
      } else if (result.status === 'not_committed') {
        localStorage.removeItem(storageKey)
        setPendingLaunch(null); setGroups([]); setSettings(null); setReviewedPersona(null); setReadiness(null); setAnswers([]); setChecks([])
        setLive(false); startedAutomatically.current = true
        setStatus('Nothing went live from this request. Review the latest assistant, settings and people before trying again.')
        onPersonaChange(result.persona)
      } else {
        throw new Error('Unconfirmed update')
      }
    } catch (caught) {
      if (current()) {
        const code = caught && typeof caught === 'object' && 'status' in caught ? caught.status : null
        setStatus(''); setError(code === 401 || code === 403
          ? 'We could not confirm whether your update went live. Sign in with access to this program, then choose Check this update.'
          : 'We still could not confirm your update. Keep this request and try Check this update again in a minute.')
      }
    } finally { if (mounted.current) setBusy(false); lifecycle.finish(ticket) }
  }
  const canPublish = Boolean(persona.permissions.publish && settings && groups.length > 0 && (reviewedPersona?.has_unpublished_changes === false || readiness))
  const voiceChanges = !live && (reviewedPersona ?? persona).has_unpublished_changes !== false
  return <article className="panel coach-go-live" aria-busy={busy}>
    <h3>{live ? 'Your program is live' : voiceChanges ? 'Hear your assistant, then go live' : 'Review changes, then go live'}</h3><p>{live ? 'Your people have the published assistant, appearance and tools.' : voiceChanges ? 'Try two everyday questions with fictional details. Review the answers before your people receive any changes.' : 'Your assistant’s voice stays the same. Review the appearance, tools and groups below.'}</p>
    {!live && !(reviewedPersona ?? persona).published_version && <><p>Preview and approve your assistant’s voice before your saved tools can go live. You can use the standard voice or edit it first.</p>{onEditVoice && <Button variant="secondary" disabled={busy || lifecycle.pending} onClick={onEditVoice}>Edit assistant’s voice</Button>}</>}
    <fieldset disabled={busy || Boolean(pendingLaunch)}><legend>Who will receive these changes?</legend>{cohorts.filter((item) => item.assignable).map((group) => <label key={group.id}><input type="checkbox" checked={groupIds.includes(group.id)} onChange={(event) => { setGroupIds((ids) => event.target.checked ? [...ids, group.id] : ids.filter((id) => id !== group.id)); setGroups([]) }} />{group.name}</label>)}{cohorts.length === 0 && <p>Create a group in People → Group invitations &amp; access first.</p>}</fieldset>
    {pendingLaunch && <><p role="note">An earlier go-live update needs confirmation. Finish it safely before starting another update.</p><div className="coach-lifecycle-actions"><Button disabled={busy || lifecycle.pending} onClick={() => void goLive()}>{busy ? 'Going live…' : 'Finish going live'}</Button><Button variant="secondary" disabled={busy || lifecycle.pending} onClick={() => void checkUpdate()}>Check this update</Button></div></>}
    {!pendingLaunch && groups.length === 0 && <Button disabled={busy || lifecycle.pending || groupIds.length === 0 || !persona.permissions.publish} onClick={() => void preview()}>{busy ? 'Preparing…' : persona.has_unpublished_changes === false ? 'Review changes' : 'Preview answers'}</Button>}
    {status && <p role="status">{status}</p>}{error && <p role="alert">{error}</p>}
    <div className="coach-answer-comparison">{answers.map((item) => <section key={item.question}><h4>{item.question}</h4><p>{item.answer}</p>{item.phraseNotice && <p className="program-help">{item.phraseNotice}</p>}</section>)}</div>
    {!pendingLaunch && groups.length > 0 && <section><h4>Review before going live</h4><p>{reviewedPersona?.draft?.identity.assistant_name ?? reviewedPersona?.name} · {groups.map((item) => `${item.group.name} (${item.participantIds.length} ${item.participantIds.length === 1 ? 'person' : 'people'})`).join(', ')}</p><p>These groups will receive this assistant, appearance and tools together.</p>
      {settings && <><BrandWelcomePreview config={settings.brand.preview.brand} />{settings.tools.map((item) => <section key={item.configuration.cohort.id}><h4>Tools for {item.configuration.cohort.name}</h4>{item.configuration.draft.experience_mode === 'savings_challenge' && item.preview.challenge_open !== true && <p>The program team still needs to open the savings challenge for this group. Participants will see “Your savings challenge opens soon” until then.</p>}{item.preview.upgrade_notice && <p>{item.preview.upgrade_notice}</p>}{toolChanges(item, groups.find(group => group.group.id === item.configuration.cohort.id)?.activeExperienceConfig).map(change => <p key={change}>{change}</p>)}<p>{item.configuration.draft.experience_mode === 'savings_challenge' ? '90-day Savings Challenge' : 'Household CFO'}</p><p>{toolNavigation(item, (reviewedPersona ?? persona).draft?.identity.assistant_name ?? 'Mia').join(' · ')}</p></section>)}</>}
      {readiness?.candidate?.audience_snapshot && <p>Who this is for: {readiness.candidate.audience_snapshot.audience === "People participating in the human coach's financial education program." ? 'People in your coaching program.' : readiness.candidate.audience_snapshot.audience}<br />Community and culture: {readiness.candidate.audience_snapshot.culture.context === 'Use only cultural and community context explicitly approved by the human coach.' ? 'Only the details you have approved.' : readiness.candidate.audience_snapshot.culture.context}</p>}
      {checks.length > 0 && <details><summary>Safety checks passed ({checks.length})</summary><ul>{checks.map((item) => <li key={item.id}>{item.case.name}: {item.status}</li>)}</ul></details>}
      {readiness?.phrase_audience_reviews.map((item) => <div className="coach-phrase-approval" key={item.artifact_id}><strong>{item.phrase.text}</strong> — {item.phrase.meaning}<small>Use: {item.phrase.allowed_contexts.map((context) => context.replaceAll('_', ' ')).join(', ')} · {item.phrase.frequency}. {item.phrase.caution}</small></div>)}
      <p id="coach-go-live-consent">{voiceChanges ? 'By choosing Approve and go live, you approve the answers, phrases, safety checks and group changes shown above.' : 'By choosing Approve and go live, you approve the appearance, tools and group changes shown above.'}</p>
      <Button aria-describedby="coach-go-live-consent" disabled={busy || !canPublish} onClick={() => void goLive()}>Approve and go live</Button>
    </section>}
  </article>
}

function toolNavigation(item: CoachSettingsReview['tools'][number], assistantName: string) {
  const savings = item.configuration.draft.experience_mode === 'savings_challenge'
  const order = item.preview.module_order ?? []
  const sections = participantSectionsForModules(item.preview.modules.filter(module => module.enabled).map(module => module.id), { moduleOrder: order, independentStatements: item.configuration.draft.schema_version >= 4 })
  const navigation = partitionParticipantSections(sections, savings, order.length > 0)
  return [...navigation.primary.map(section => participantSectionLabel(section, savings, assistantName, section === 'Ask Mia')), ...(navigation.secondary.length ? [`More: ${navigation.secondary.map(section => participantSectionLabel(section, savings, assistantName, section === 'Ask Mia')).join(' · ')}`] : [])]
}
