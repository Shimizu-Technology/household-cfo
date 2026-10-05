import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent, type ReactNode } from 'react'
import { ApiRequestError, approveSavingsEntry, approveSavingsPlan, attestSavingsZero, enrollSavingsChallenge, fetchSavingsChallenge, fetchSavingsPage, stageSavingsEntry, stageSavingsPlan, type SavingsCollection } from '../api'
import { savingsDefaultDate, savingsDollars, savingsFundingLabel, savingsFundingOptions, savingsInputCents, savingsInputDollars, type SavingsChallenge, type SavingsEntry, type SavingsEntryVersion, type SavingsEntryDraft, type SavingsFundingSource, type SavingsMutation, type SavingsPage, type SavingsPlanDraft, type SavingsIntake } from '../lib/savingsChallenge'
import { useBrand } from '../contexts/brandContextValue'
import { ComfortablePlanChoices, ComfortablePlanSummary, type ComfortablePlanState } from './ComfortablePlanChoices'
import { SavingsPlanApprovalReview } from './SavingsPlanApprovalReview'
import type { BaselineScope } from '../lib/financialBaseline'
import { dailyResponseMatches, type DailyScope } from '../lib/dailyChallenge'
import { useComfortablePlanMutation } from '../lib/useComfortablePlanMutation'
import { fencePlanActor, readPlanRequest } from '../lib/comfortablePlanRecovery'
import { PlanRequestRecovery } from './PlanRequestRecovery'
import { savingsPlanContextInput } from '../lib/savingsChallenge'
import { useHomeSavingsMutation } from '../lib/useHomeSavingsMutation'
import { HomeSavingsRequestRecovery } from './HomeSavingsRequestRecovery'
import type { HomeSavingsAction } from '../lib/homeSavingsRecovery'
import './SavingsChallengeHome.css'

type RecordRow = SavingsEntry | SavingsEntryVersion | SavingsEntryDraft | SavingsPlanDraft
type Retry = { key: string; perform: (key: string, signal: AbortSignal) => Promise<SavingsMutation<unknown>>; done?: () => void }
type HomeProps = { onOptionalDebt?: () => void; cohortId?: number; evidenceRefreshToken?: number; onReviewEvidence?: (entryVersionId:number)=>void; participantScope?: BaselineScope; onAskMia: () => void; onReviewStatements: () => void; onReviewBaseline?: () => void; onToday?: () => void; onPrivacy?: () => void; initialSavingsIntake?: SavingsIntake | null }
export function SavingsChallengeHome(props: HomeProps) { return <SavingsChallengeHomeBody key={`${props.participantScope?.user_id}:${props.participantScope?.household_id}:${props.cohortId}`} {...props}/> }
function SavingsChallengeHomeBody({ onOptionalDebt, cohortId, evidenceRefreshToken, onAskMia, onReviewStatements, onReviewBaseline, onToday, onPrivacy, initialSavingsIntake, participantScope, onReviewEvidence }: HomeProps) {
  const { assistantName } = useBrand()
  const [planOpen, setPlanOpen] = useState(false)
  const [entryOpen, setEntryOpen] = useState(Boolean(initialSavingsIntake))
  const [historyOpen, setHistoryOpen] = useState(false)
  const [challenge, setChallenge] = useState<SavingsChallenge | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [readFailed, setReadFailed] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [retry, setRetry] = useState<Retry | null>(null)
  const [revision, setRevision] = useState(0)
  const [reviewAnchor, setReviewAnchor] = useState<{ collection: 'plan_drafts' | 'entry_drafts'; id: number } | null>(null)
  const [participation, setParticipation] = useState(false)
  const [lateAcceptance, setLateAcceptance] = useState(false)
  const [comfortable, setComfortable] = useState<ComfortablePlanState>({edited:false,reviewed:false})
  const [target, setTarget] = useState('500.00')
  const [postponed, setPostponed] = useState(false)
  const [planReason, setPlanReason] = useState('')
  const [amount, setAmount] = useState(initialSavingsIntake ? savingsInputDollars(initialSavingsIntake.amount_cents) : '')
  const [intakeActive,setIntakeActive] = useState(Boolean(initialSavingsIntake))
  const [newMoneyReviewed,setNewMoneyReviewed] = useState(false)
  const [effectiveOn, setEffectiveOn] = useState(initialSavingsIntake?.effective_on ?? '')
  const [funding, setFunding] = useState<SavingsFundingSource>('new_money_reserved')
  const [withdrawal, setWithdrawal] = useState(initialSavingsIntake?.kind==='withdrawal')
  const [entryReason, setEntryReason] = useState('')
  const [editingEntry, setEditingEntry] = useState<SavingsEntry | null>(null)
  const [knownZero, setKnownZero] = useState(false)
  const privateDenied = useRef(false)
  const mounted = useRef(false)
  const sequence = useRef(0)
  const working = useRef(false)
  const uncertainRequest = useRef(false)
  const lastOffer = useRef<string | null>(null)
  const initializedPlan = useRef(false)
  const controllers = useRef(new Set<AbortController>())
  const clearPrivatePlan = useCallback(() => { privateDenied.current=true; sequence.current++;for(const controller of controllers.current)controller.abort();controllers.current.clear();setLoading(false);setParticipation(false);setLateAcceptance(false);setKnownZero(false);setNewMoneyReviewed(false);setIntakeActive(false);setWithdrawal(false);setFunding('new_money_reserved');setComfortable({edited:false,reviewed:false}); setChallenge(null); setReadFailed(true); setError('Private plan access is no longer available.'); setAmount(''); setEffectiveOn(''); setPlanReason(''); setEntryReason(''); setEditingEntry(null); setTarget('500.00') }, [])
  const requestErrorRef = useRef<HTMLDivElement>(null)
  const entryHeadingRef = useRef<HTMLHeadingElement>(null)
  const targetHeadingRef = useRef<HTMLHeadingElement>(null)
  const progressHeadingRef = useRef<HTMLHeadingElement>(null)
  const [focusAfterJoin,setFocusAfterJoin] = useState(false)
  const focusJoined = () => setFocusAfterJoin(true)
  useEffect(()=>{if(!focusAfterJoin||!challenge?.enrollment)return;const frame=requestAnimationFrame(()=>{progressHeadingRef.current?.scrollIntoView({block:'start'});progressHeadingRef.current?.focus();setFocusAfterJoin(false)});return()=>cancelAnimationFrame(frame)},[focusAfterJoin,challenge?.enrollment])
  const scopeUser = participantScope?.user_id, scopeHousehold = participantScope?.household_id, scopeEnrollment = challenge?.enrollment?.id
  const planScope = useMemo(() => scopeUser && scopeHousehold && scopeEnrollment ? {user_id:scopeUser,household_id:scopeHousehold,enrollment_id:scopeEnrollment} : undefined, [scopeUser,scopeHousehold,scopeEnrollment])
  useEffect(() => { if(participantScope) fencePlanActor(participantScope) }, [participantScope])
  const receivePlan = useCallback((result:SavingsMutation<unknown>) => {sequence.current++;for(const controller of controllers.current)controller.abort();controllers.current.clear();setLoading(false);setChallenge(result.challenge);setReadFailed(false);setError(null);setNotice(result.replayed?'Your earlier plan request was confirmed once.':'Plan preview saved. Spending choices do not count as savings.');setRevision(value=>value+1);const record=result.record as {id?:number;status?:string};if(record.status==='pending'&&record.id)setReviewAnchor({collection:'plan_drafts',id:record.id})}, [])
  const planMutation = useComfortablePlanMutation(planScope, receivePlan, clearPrivatePlan, revision)
  const scopeCohort = cohortId ?? challenge?.enrollment?.cohort_id
  const homeScope = useMemo(() => scopeUser && scopeHousehold && scopeCohort ? {user_id:scopeUser,household_id:scopeHousehold,cohort_id:scopeCohort} : undefined, [scopeUser,scopeHousehold,scopeCohort])
  const historyScope = useMemo(() => homeScope && scopeEnrollment ? {...homeScope,enrollment_id:scopeEnrollment} : undefined, [homeScope,scopeEnrollment])
  const receiveHome = useCallback((result:SavingsMutation<unknown>,action:HomeSavingsAction) => { sequence.current++;for(const controller of controllers.current)controller.abort();controllers.current.clear();setLoading(false);setChallenge(result.challenge);setReadFailed(false);setError(null);setNotice(result.replayed?'Your earlier request was confirmed once.':'Saved. Only approved records count toward reported progress.');setRevision(value=>value+1);const draft=result.record as {id?:number;status?:string;signed_cents?:number};if(draft.status==='pending'&&draft.id){setEntryOpen(true);setReviewAnchor({collection:'entry_drafts',id:draft.id})};setEffectiveOn(current=>current||savingsDefaultDate(result.challenge.calendar));if(action==='enrollment')focusJoined() }, [])
  const homeConflict = useCallback((message: string) => { setReadFailed(true); setParticipation(false); setLateAcceptance(false); setKnownZero(false); setError(message) }, [])
  const homeMutation = useHomeSavingsMutation(homeScope, receiveHome, clearPrivatePlan, () => Boolean(readPlanRequest(planScope)) || working.current, homeConflict)
  const homePendingRef = useRef(homeMutation.pending); useEffect(()=>{homePendingRef.current=homeMutation.pending},[homeMutation.pending])
  const refresh = useCallback(async () => {
    if (!mounted.current || privateDenied.current || working.current || uncertainRequest.current || homePendingRef.current?.working || homePendingRef.current?.attempt || (readPlanRequest(planScope) && !readPlanRequest(planScope)?.awaitingFreshReview)) return
    const epoch = ++sequence.current
    const controller = new AbortController(); controllers.current.add(controller)
    setLoading(true)
    try {
      const next = await fetchSavingsChallenge(controller.signal)
      if (!mounted.current || epoch !== sequence.current) return
      const receivedCohort = (next as SavingsChallenge & {cohort_id?:number}).cohort_id ?? next.enrollment?.cohort_id
      if (homeScope && receivedCohort !== undefined && receivedCohort !== homeScope.cohort_id) throw new ApiRequestError('The private challenge program changed. Reopen Home.', {status:403})
      const offerIdentity = JSON.stringify(next.offer ?? null)
      if (lastOffer.current !== offerIdentity) { setParticipation(false); setLateAcceptance(false); lastOffer.current = offerIdentity }
      if (!initializedPlan.current && next.enrollment) {
        initializedPlan.current = true
        if (!next.accepted_plan) setPlanOpen(true)
        if (next.accepted_plan) { setPostponed(next.accepted_plan.target_cents === null); if (next.accepted_plan.target_cents !== null) setTarget(savingsInputDollars(next.accepted_plan.target_cents)) }
      }
      setChallenge(next); setReadFailed(false); setError(null); setRevision((value) => value + 1)
      setEffectiveOn((current) => current || savingsDefaultDate(next.calendar))
    } catch (failure) {
      if (!mounted.current || epoch !== sequence.current) return
      setError(message(failure)); setReadFailed(true)
      if (failure instanceof ApiRequestError && [401, 403, 404].includes(failure.status)) {
        privateDenied.current=true;
        setComfortable({edited:false,reviewed:false}); setChallenge(null); setEditingEntry(null); setTarget('500.00')
        setAmount(''); setEffectiveOn(''); setEntryReason(''); setPlanReason(''); setParticipation(false); setLateAcceptance(false); setKnownZero(false)
      }
    } finally {
      controllers.current.delete(controller)
      if (mounted.current && epoch === sequence.current) setLoading(false)
    }
  }, [planScope, homeScope])
  useEffect(() => {
    mounted.current = true
    const ownedControllers = controllers.current
    queueMicrotask(() => { void refresh() })
    const check = () => { if (!document.hidden) void refresh() }
    window.addEventListener('focus', check); document.addEventListener('visibilitychange', check)
    const timer = setInterval(check, 30_000)
    return () => {
      mounted.current = false; sequence.current += 1
      for (const controller of ownedControllers) controller.abort()
      ownedControllers.clear(); clearInterval(timer)
      window.removeEventListener('focus', check); document.removeEventListener('visibilitychange', check)
    }
  }, [refresh])
  async function mutate(attempt: Retry) {
    if (working.current || homeMutation.isPending() || readPlanRequest(planScope)) return
    working.current = true
    const epoch = ++sequence.current
    for (const controller of controllers.current) controller.abort()
    controllers.current.clear()
    const controller = new AbortController(); controllers.current.add(controller)
    setBusy(true); setError(null); setNotice(null)
    try {
      const result = await attempt.perform(attempt.key, controller.signal)
      if (!mounted.current || epoch !== sequence.current) return
      setChallenge(result.challenge); setReadFailed(false); setRevision((value) => value + 1); setRetry(null); uncertainRequest.current = false
      setNotice(result.replayed ? 'Your earlier request was confirmed. It was not added twice.' : 'Saved. Only approved records count toward reported progress.')
      const draft = result.record as { id?: number; status?: string; signed_cents?: number }
      if (draft.status === 'pending' && draft.id && Number.isSafeInteger(draft.id)) { if (draft.signed_cents === undefined) setPlanOpen(true); else setEntryOpen(true) }
      if (draft.status === 'pending' && draft.id && Number.isSafeInteger(draft.id)) setReviewAnchor({ collection: draft.signed_cents === undefined ? 'plan_drafts' : 'entry_drafts', id: draft.id })
      attempt.done?.()
      if (!draft.status && result.challenge.enrollment && !challenge?.enrollment) focusJoined()
      setEffectiveOn((current) => current || savingsDefaultDate(result.challenge.calendar))
    } catch (failure) {
      if (!mounted.current || epoch !== sequence.current) return
      setError(message(failure))
      if (failure instanceof ApiRequestError && failure.status === 409) setReadFailed(true)
      const uncertain = !(failure instanceof ApiRequestError) || failure.status >= 500
      setRetry(uncertain ? attempt : null); uncertainRequest.current = uncertain
      if (failure instanceof ApiRequestError && [401, 403, 404].includes(failure.status)) {
        privateDenied.current=true;
        setComfortable({edited:false,reviewed:false}); setChallenge(null); setEditingEntry(null); setAmount(''); setEffectiveOn(''); setEntryReason(''); setPlanReason('')
      }
      requestAnimationFrame(() => requestErrorRef.current?.focus())
    } finally {
      controllers.current.delete(controller)
      if (mounted.current && epoch === sequence.current) { setBusy(false); setLoading(false); working.current = false }
    }
  }
  const locked = busy || loading || readFailed || retry !== null || homeMutation.pending !== null || planMutation.busy || planMutation.needsRefresh
  const planFormLocked = busy || loading || readFailed || retry !== null || homeMutation.pending !== null || planMutation.needsRefresh || Boolean(planMutation.pending && planMutation.freshAction?.action !== 'plan_stage')
  function stage(perform: Retry['perform'], done?: () => void) { void mutate({ key: crypto.randomUUID(), perform, done }) }
  function homeStage(action:HomeSavingsAction, perform:Retry['perform'], done?:()=>void, draftId?:number, entryId?:number) {
    if(actionLocked(action,draftId,entryId) || readPlanRequest(planScope) || working.current || homeMutation.pending?.working) return
    for(const controller of controllers.current)controller.abort();controllers.current.clear();sequence.current++;setLoading(false)
    if(homeScope) void homeMutation.submit({action, enrollmentId:action==='enrollment'?null:challenge?.enrollment?.id??null,draftId,entryId,perform,done})
    else stage(perform,done)
  }
  const freshHome = homeMutation.pending?.fresh ? homeMutation.pending : null
  const actionLocked = (action:HomeSavingsAction, draftId?:number, entryId?:number) => busy || loading || readFailed || retry !== null || planMutation.busy || planMutation.needsRefresh || Boolean(homeMutation.pending && !(freshHome?.action===action && freshHome.draftId===draftId && freshHome.entryId===entryId))
  const entryFormLocked = actionLocked('entry_stage',undefined,editingEntry?.id)
  function prepareHomeFresh() { const pending=homeMutation.pending; if(pending?.action==='entry_stage'||pending?.action==='entry_approve')setEntryOpen(true);if(pending?.action==='entry_approve'&&pending.draftId)setReviewAnchor({collection:'entry_drafts',id:pending.draftId});setParticipation(false);setLateAcceptance(false);setKnownZero(false);setAmount('');setEntryReason('');setEditingEntry(null);void refresh() }
  const appliedEvidenceToken = useRef(evidenceRefreshToken)
  useEffect(()=>{if(evidenceRefreshToken===appliedEvidenceToken.current||busy||loading||retry||homeMutation.pending||planMutation.pending)return;appliedEvidenceToken.current=evidenceRefreshToken;void refresh()},[evidenceRefreshToken,busy,loading,retry,homeMutation.pending,planMutation.pending,refresh])
  function validate(action: () => void) {
    try { setError(null); action() } catch (failure) { setError(message(failure)); requestAnimationFrame(() => requestErrorRef.current?.focus()) }
  }
  function submitPlan(event: FormEvent) {
    event.preventDefault()
    if (planFormLocked || homeMutation.isPending() || !challenge?.enrollment) return
    validate(() => {
      const target_cents = postponed ? null : savingsInputCents(target)
      const expected_plan_version_id = challenge.enrollment!.current_accepted_plan_version_id
      if (expected_plan_version_id && !planReason.trim()) throw new Error('Explain the target change before review.')
      if (comfortable.edited && (!comfortable.reviewed || comfortable.error || !comfortable.input)) throw new Error(comfortable.error || 'Review your optional spending choices before preparing this plan.')
      const context = comfortable.edited ? comfortable.input : savingsPlanContextInput(challenge.accepted_plan)
      const input = { target_cents, expected_plan_version_id, reason: planReason, ...context }
      if (participantScope) void planMutation.perform('plan_stage', input)
      else stage((key, signal) => stageSavingsPlan(input, key, signal))
    })
  }
  function submitEntry(event: FormEvent) {
    event.preventDefault()
    if (entryFormLocked || !challenge?.enrollment) return
    validate(() => {
      if (intakeActive && !withdrawal && savingsFundingOptions.find(option=>option.value===funding)?.eligible && !newMoneyReviewed) throw new Error('Confirm the new money actually set aside before reviewing this contribution.')
      const cents = savingsInputCents(amount, editingEntry !== null)
      if (!effectiveOn || effectiveOn < challenge.enrollment!.starts_on || effectiveOn > challenge.enrollment!.ends_on) throw new Error('Choose a date within your personal challenge window.')
      if (!challenge.calendar || effectiveOn > challenge.calendar.local_today) throw new Error('Report money already set aside. Future promises cannot be approved as actual savings.')
      if (editingEntry && !entryReason.trim()) throw new Error('Explain the correction before review.')
      const input = { signed_cents: withdrawal ? -cents : cents, effective_on: effectiveOn, funding_source: withdrawal ? 'withdrawal' as const : funding, expected_version_id: editingEntry?.current_approved_version_id ?? null, ...(editingEntry ? { entry_id: editingEntry.id, expected_entry_lock_version: editingEntry.lock_version } : {}), reason: entryReason }
      homeStage('entry_stage',(key, signal) => stageSavingsEntry(input, key, signal), () => { setIntakeActive(false); setAmount(''); setEditingEntry(null); setEntryReason('') },undefined,editingEntry?.id)
    })
  }
  function editEntry(entry: SavingsEntry) {
    const value = entry.current_approved_version
    if (!value || actionLocked('entry_stage',undefined,entry.id)) return
    setEntryOpen(true); setEditingEntry(entry); setAmount(savingsInputDollars(value.signed_cents)); setWithdrawal(value.funding_source === 'withdrawal'); setFunding(value.funding_source === 'withdrawal' ? 'new_money_reserved' : value.funding_source); setEffectiveOn(value.effective_on); setEntryReason('')
    requestAnimationFrame(() => { entryHeadingRef.current?.scrollIntoView({ block: 'center' }); entryHeadingRef.current?.focus() })
  }
  const projection = challenge?.projection
  const calendar = challenge?.calendar
  const elapsed = calendar && calendar.phase !== 'upcoming'
  const offer = challenge?.offer
  return <section className="savings-home screen-grid" aria-label="Savings challenge">
    <div className="screen-heading"><p className="eyebrow">Home</p><h2 data-page-heading tabIndex={-1}>Your savings challenge</h2><p>Build a reserve at your pace. Protect essentials first; choose a target you can afford.</p></div>
    {error && <div className="savings-error" role="alert" tabIndex={-1} ref={requestErrorRef}><p>{error}</p>{retry ? <><p>The server has not confirmed this request. Retry the same request before making another change.</p><button type="button" disabled={busy} onClick={() => void mutate(retry)}>Retry same request</button></> : <button type="button" disabled={busy} onClick={() => {privateDenied.current=false;void refresh()}}>Refresh challenge</button>}</div>}
    <HomeSavingsRequestRecovery state={homeMutation} onFresh={prepareHomeFresh}/>
    {freshHome?.action==='entry_stage'&&freshHome.entryId&&<p role="status">Re-open correction for record #{freshHome.entryId} in approved history below. Only that record can be re-reviewed.</p>}
    {(planMutation.pending || planMutation.error) && <PlanRequestRecovery state={planMutation} onRefresh={()=>void refresh()}/>}
    {notice && <p className="savings-notice" role="status">{notice}</p>}
    {readFailed && challenge && <p role="status">Last approved result shown. Access and freshness could not be confirmed; refresh before making changes.</p>}
    {loading && <p role="status">Checking your approved challenge…</p>}
    {!challenge && !loading && <p>Your challenge is unavailable. No progress is being assumed.</p>}
    {challenge && !challenge.enrollment && <article className="panel savings-enrollment"><h3>Review before joining</h3><p>The suggested target is {savingsDollars(challenge.suggested_target_cents ?? null)}. You choose an affordable amount after joining, or postpone choosing a target.</p>
      {offer ? <><p><strong>{offer.cohort_label}</strong> · {offer.time_zone}</p><p>Your proposed 90-day window: <strong>{offer.personal_starts_on ?? 'Not configured'} – {offer.personal_ends_on ?? 'Not configured'}</strong>.</p><p>Participation records your reported reserve and approvals. It does not move money, connect a bank, or require a credit card or full budget.</p><p>Statement uploads are optional and require separate review. This acceptance does not grant a coach access to your private statements.</p><p className="savings-caption">Participation policy: {offer.policy_version}. Cohort capacity is checked again when you accept.</p><label className="savings-check"><input type="checkbox" checked={participation} disabled={actionLocked('enrollment')} onChange={(event) => setParticipation(event.target.checked)} />I have read this notice and accept participation.</label>
        {offer.late_start_acceptance_required && <label className="savings-check"><input type="checkbox" checked={lateAcceptance} disabled={actionLocked('enrollment')} onChange={(event) => setLateAcceptance(event.target.checked)} />I accept the later personal start and the full window shown above.</label>}
        <button type="button" disabled={actionLocked('enrollment') || !offer.accepting_enrollments || !participation || Boolean(offer.late_start_acceptance_required && !lateAcceptance)} onClick={() => homeStage('enrollment',(key, signal) => enrollSavingsChallenge({ participation_accepted: true, policy_version: offer.policy_version, late_start_accepted: lateAcceptance, expected_acceptance_digest: offer.acceptance_digest }, key, signal))}>Accept and join</button>
        {!offer.accepting_enrollments && <p role="status">This cohort is not accepting enrollment right now.</p>}</> : <p>Enrollment terms are unavailable. Refresh to review them before joining.</p>}
    </article>}
    {challenge?.enrollment && <>
      <article className="panel savings-progress" aria-label="Approved savings progress"><h3 ref={progressHeadingRef} tabIndex={-1}>Your approved progress</h3>{onToday&&<button type="button" onClick={onToday}>Open Today & checkpoints</button>}<div><p className="eyebrow">Participant reported reserve</p><strong className="savings-total">{savingsDollars(projection?.reported_cents ?? null)}</strong><p>{projection?.reporting_known ? `As of ${projection.cutoff_on}. Approved contributions less withdrawals.` : 'No approved eligible report yet. Unknown does not mean zero.'}</p></div>
        <div className="savings-target"><span>Accepted target</span><strong>{challenge.accepted_plan ? challenge.accepted_plan.target_cents === null ? 'Choosing later' : savingsDollars(challenge.accepted_plan.target_cents) : 'Not yet approved'}</strong><button type="button" disabled={locked} onClick={() => { if (challenge.accepted_plan && elapsed) setEntryOpen(true); else setPlanOpen(true); requestAnimationFrame(() => { const destination = challenge.accepted_plan && elapsed ? entryHeadingRef.current : targetHeadingRef.current; destination?.scrollIntoView({ block: 'center' }); destination?.focus() }) }}>{challenge.accepted_plan && elapsed ? 'Report savings' : challenge.accepted_plan ? 'View target plan' : 'Choose target'}</button></div>
        {projection?.progress_basis_points !== null && projection?.progress_basis_points !== undefined && <><progress aria-label="Approved target progress" max={10000} value={projection.progress_basis_points} /><p>{(projection.progress_basis_points / 100).toFixed(1)}% of your accepted target{projection.reported_cents !== null && projection.reported_cents < 0 ? '. The reserve is below zero; the progress bar stays at zero.' : '.'}</p></>}
        <p className="savings-caption">Evidence-supported subset: {savingsDollars(projection?.evidence_supported_cents ?? null)}. Self-reports are not bank-verified; imported bank movements do not automatically count as savings.</p>
        {projection && <p className="savings-caption">{projection.excluded_entry_count} excluded approved record{projection.excluded_entry_count === 1 ? '' : 's'}. {challenge.pending_entry_count ?? 0} pending contribution review{challenge.pending_entry_count === 1 ? '' : 's'}.</p>}
      </article>
      {calendar && <section className="savings-calendar" aria-label="Personal challenge calendar"><div><strong>{calendar.phase === 'upcoming' ? 'Starts soon' : calendar.phase === 'window_ended' ? 'Reporting window ended' : `Day ${calendar.day} of 90`}</strong><span>{calendar.starts_on} – {calendar.ends_on} · {calendar.time_zone}</span></div><ol>{(['30', '60', '90'] as const).map((day) => <li key={day}><span>Day {day}</span><strong>{calendar.checkpoints[day]}</strong></li>)}</ol><p>These are your frozen personal dates. A checkpoint date does not imply a completed check-in.</p></section>}
      <div className="savings-workflows">
        <details className="savings-task panel" open={planOpen} onToggle={event => setPlanOpen(event.currentTarget.open)}><summary>{challenge.accepted_plan ? `Target & spending choices${challenge.pending_plan_count ? ` · ${challenge.pending_plan_count} to review` : ''}` : 'Choose your target'}</summary><section aria-label="Savings target plan"><h3 ref={targetHeadingRef} tabIndex={-1}>{challenge.accepted_plan ? 'Review a target change' : 'Choose your affordable target'}</h3><p>The suggested $500 is a starting point. Approve a positive custom target or choose it later.</p><p>{challenge.pending_plan_count} target plan review{challenge.pending_plan_count === 1 ? '' : 's'} pending.</p>{challenge.accepted_plan && <section aria-label="Accepted spending choices"><h4>Current accepted plan</h4><ComfortablePlanSummary plan={challenge.accepted_plan}/></section>}<form onSubmit={submitPlan}><fieldset disabled={planFormLocked}><label>Target in US dollars<input inputMode="decimal" value={target} disabled={postponed} onChange={(event) => setTarget(event.target.value)} /></label><label className="savings-check"><input type="checkbox" checked={postponed} onChange={(event) => setPostponed(event.target.checked)} />I will choose my target later</label>{challenge.accepted_plan && <label>Reason for target change<textarea maxLength={500} value={planReason} onChange={(event) => setPlanReason(event.target.value)} required /></label>}<ComfortablePlanChoices key={`${participantScope?.user_id}:${participantScope?.household_id}:${challenge.enrollment.id}`} acceptedPlan={challenge.accepted_plan} scope={participantScope} disabled={planFormLocked} freshness={revision} onChange={setComfortable} onDenied={clearPrivatePlan} onBaseline={onReviewBaseline}/>{comfortable.error && <p className="savings-caption">{comfortable.error}</p>}<button type="submit" disabled={comfortable.edited && (!comfortable.reviewed || Boolean(comfortable.error))}>Review target plan</button></fieldset></form>
          <SavingsHistory<SavingsPlanDraft> scope={historyScope} onDenied={clearPrivatePlan} key={reviewAnchor?.collection === 'plan_drafts' ? `plan:${reviewAnchor.id}` : 'plan'} focusRecordId={reviewAnchor?.collection === 'plan_drafts' ? reviewAnchor.id : undefined} collection="plan_drafts" label="Target plan reviews" revision={revision} enabled={!busy} render={(draft) => <><p><strong>{draft.target_cents === null ? 'Choose target later' : savingsDollars(draft.target_cents)}</strong> · {draft.status}</p>{draft.reason && <p>{draft.reason}</p>}{draft.status === 'pending' && <><SavingsPlanApprovalReview key={`${draft.id}:${draft.lock_version}:${revision}`} draft={draft} disabled={busy || loading || readFailed || planMutation.needsRefresh || Boolean(planMutation.pending && !(planMutation.freshAction?.action === 'plan_approve' && planMutation.freshAction.draftId === draft.id)) || retry !== null || homeMutation.pending !== null} onApprove={() => {if(homeMutation.isPending())return;const input={accepted:true as const,expected_draft_lock_version:draft.lock_version,expected_plan_version_id:draft.base_plan_version_id};if(participantScope)void planMutation.perform('plan_approve',input,draft.id);else stage((key,signal)=>approveSavingsPlan(draft.id,input,key,signal))}}/></>}</>} />
        </section></details>
        <details className="savings-task panel" open={entryOpen} onToggle={event => setEntryOpen(event.currentTarget.open)}><summary>Report savings{challenge.pending_entry_count ? ` · ${challenge.pending_entry_count} to review` : ''}</summary><section aria-label="Report actual savings"><h3 ref={entryHeadingRef} tabIndex={-1}>{editingEntry ? `Correct savings record #${editingEntry.id}` : 'Report money already set aside'}</h3><p>This records a past contribution to your reserve; it does not transfer money. Debt repayments and moving existing money are not new savings.</p><form onSubmit={submitEntry}><fieldset disabled={entryFormLocked || !elapsed}><label>Amount in US dollars<input inputMode="decimal" value={amount} onChange={(event) => { setNewMoneyReviewed(false); setAmount(event.target.value) } } required /></label><label className="savings-check"><input type="checkbox" checked={withdrawal} onChange={(event) => { setNewMoneyReviewed(false); setWithdrawal(event.target.checked) }} />I withdrew this amount from my challenge reserve</label><label>Date money was set aside or withdrawn<input type="date" value={effectiveOn} min={challenge.enrollment.starts_on} max={calendar?.local_today && calendar.local_today < challenge.enrollment.ends_on ? calendar.local_today : challenge.enrollment.ends_on} onChange={(event) => { setNewMoneyReviewed(false); setEffectiveOn(event.target.value) } } required /></label>{!withdrawal && <label>Where did this money come from?<select value={funding} onChange={(event) => { setNewMoneyReviewed(false); setFunding(event.target.value as SavingsFundingSource) }}>{savingsFundingOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</select></label>}{!withdrawal && !savingsFundingOptions.find((option) => option.value === funding)?.eligible && <p className="savings-excluded">This records context only. It will be excluded from reported progress.</p>}{editingEntry && <label>Reason for correction<textarea maxLength={500} value={entryReason} onChange={(event) => setEntryReason(event.target.value)} required /></label>}{intakeActive && <><p>Unreviewed note from Mia. Nothing is counted; check the actual date and funding source.</p>{!withdrawal && savingsFundingOptions.find(option=>option.value===funding)?.eligible && <label className="savings-check"><input type="checkbox" checked={newMoneyReviewed} onChange={event=>setNewMoneyReviewed(event.target.checked)}/>I confirm this was new money actually set aside after expenses, not borrowed or existing money.</label>}</>}<button type="submit" disabled={intakeActive && !withdrawal && Boolean(savingsFundingOptions.find(option=>option.value===funding)?.eligible) && !newMoneyReviewed}>Review savings record</button>{editingEntry && <button type="button" onClick={() => { setEditingEntry(null); setAmount(''); setEntryReason('') }}>Cancel correction</button>}</fieldset></form>{!elapsed && <p>Actual contributions can be reported once your personal window starts.</p>}
          <SavingsHistory<SavingsEntryDraft> scope={historyScope} onDenied={clearPrivatePlan} key={reviewAnchor?.collection === 'entry_drafts' ? `entry:${reviewAnchor.id}` : 'entry'} focusRecordId={reviewAnchor?.collection === 'entry_drafts' ? reviewAnchor.id : undefined} collection="entry_drafts" label="Savings record reviews" revision={revision} enabled={!busy} render={(draft) => <><p><strong>{savingsDollars(draft.signed_cents)}</strong> · {draft.effective_on} · {draft.status}</p><p>{savingsFundingLabel(draft.funding_source)}</p>{draft.reason && <p>{draft.reason}</p>}{draft.status === 'pending' && <><p>Pending review. Approved totals remain unchanged.</p><button type="button" disabled={actionLocked('entry_approve',draft.id) || !calendar || draft.effective_on > calendar.local_today} onClick={() => homeStage('entry_approve',(key, signal) => approveSavingsEntry(draft.id, { accepted: true, expected_draft_lock_version: draft.lock_version, expected_version_id: draft.base_version_id, expected_entry_lock_version: draft.base_entry_lock_version }, key, signal),undefined,draft.id)}>Approve savings record #{draft.id}</button>{(!calendar || draft.effective_on > calendar.local_today) && <p>Future promise: approval is unavailable until the date has elapsed.</p>}</>}</>} />
        </section></details>
      </div>
      {projection && !projection.reporting_known && elapsed && <details className="savings-task panel"><summary>No new savings to report?</summary><section className="savings-zero" aria-label="Confirm known zero"><h3>No new reserve to report?</h3><p>Leave the amount unknown if you are unsure. If you know your eligible reserve is zero through {projection.cutoff_on}, explicitly confirm it.</p><label className="savings-check"><input type="checkbox" checked={knownZero} disabled={actionLocked('zero_attest')} onChange={(event) => setKnownZero(event.target.checked)} />I know I have no eligible contributions or withdrawals to report through this date.</label><button type="button" disabled={actionLocked('zero_attest') || !knownZero} onClick={() => homeStage('zero_attest',(key, signal) => attestSavingsZero({ known_zero: true, cutoff_on: projection.cutoff_on, expected_enrollment_lock_version: challenge.enrollment!.lock_version }, key, signal), () => setKnownZero(false))}>Confirm known zero</button></section></details>}
      <details className="savings-task panel" open={historyOpen} onToggle={event => setHistoryOpen(event.currentTarget.open)}><summary>Your approved records &amp; corrections</summary><section aria-label="Approved savings history"><h3>Your approved records</h3><p>Corrections are separate proposals. The current approved version remains in your total until you approve its replacement.</p><SavingsHistory<SavingsEntry> scope={historyScope} onDenied={clearPrivatePlan} key={freshHome?.entryId??'entries'} focusRecordId={freshHome?.entryId} collection="entries" label="Savings history" revision={revision} enabled={!busy} render={(entry) => entry.current_approved_version ? <><p><strong>{savingsDollars(entry.current_approved_version.signed_cents)}</strong> · {entry.current_approved_version.effective_on} · version {entry.current_approved_version.version_number}</p><p>{savingsFundingLabel(entry.current_approved_version.funding_source)} · Participant reported. Evidence: {({not_linked:'Not linked',linked:'Linked to reviewed proof',stale:'Linked proof needs review',revoked:'Proof link revoked'} as const)[entry.current_approved_version.evidence_status] ?? 'Status unavailable'}. Supported subset: {savingsDollars(entry.current_approved_version.evidence_supported_cents ?? null)}; this is part of the reported amount, not additional savings.</p>{onReviewEvidence && entry.current_approved_version.signed_cents > 0 && savingsFundingOptions.some(option=>option.value===entry.current_approved_version!.funding_source&&option.eligible) && <button type="button" disabled={locked} onClick={()=>onReviewEvidence(entry.current_approved_version!.id)}>Review savings evidence</button>}<button type="button" disabled={actionLocked('entry_stage',undefined,entry.id)} onClick={() => editEntry(entry)}>Correct record #{entry.id}</button></> : <p>Record #{entry.id} has no approved version. Check its pending review.</p>} />{onReviewEvidence&&<details><summary>Savings entry revision history</summary><p>These are approved revisions. Totals use only each record’s current version. An old proof linkage can be explicitly revoked to free its reserved movement capacity.</p><SavingsHistory<SavingsEntryVersion> scope={historyScope} onDenied={clearPrivatePlan} collection="entry_versions" label="Savings entry revisions" revision={revision} enabled={!busy} render={(version)=><><p><strong>{savingsDollars(version.signed_cents)}</strong> · {version.effective_on} · revision {version.version_number}</p><p>{savingsFundingLabel(version.funding_source)} · {version.reason}</p>{version.signed_cents>0&&savingsFundingOptions.some(option=>option.value===version.funding_source&&option.eligible)&&<button type="button" disabled={locked} onClick={()=>onReviewEvidence(version.id)}>Review proof for savings revision {version.version_number}</button>}</>}/></details>}</section></details>
    </>}
    <details className="savings-support"><summary>Optional support &amp; deeper money tools</summary><nav className="savings-next" aria-label="Optional challenge support">{onToday && challenge?.enrollment && <button type="button" onClick={(event) => { event.currentTarget.focus(); onToday() }}>Today & checkpoints</button>}<button type="button" onClick={onAskMia}>Talk with {assistantName}</button><button type="button" onClick={onReviewStatements}>Review or upload statements</button>{onReviewBaseline && <button type="button" onClick={(event) => { event.currentTarget.focus(); onReviewBaseline?.() }}>Review spending baseline</button>}{onPrivacy && <button type="button" onClick={(event)=>{event.currentTarget.focus();onPrivacy()}}>Privacy & notifications</button>}{onOptionalDebt && challenge?.enrollment && <button type="button" onClick={onOptionalDebt}>Optional card &amp; debt review</button>}<p>Statements, debt details, a baseline, and a full household budget are optional.</p></nav></details>
  </section>
}
function SavingsHistory<T extends RecordRow>({ collection, label, revision, enabled, render, focusRecordId, scope, onDenied }: { scope?: DailyScope; onDenied?: () => void; focusRecordId?: number; collection: SavingsCollection; label: string; revision: number; enabled: boolean; render: (record: T) => ReactNode }) {
  const [page, setPage] = useState<SavingsPage<T> | null>(null)
  const [cursor, setCursor] = useState<number | null>(focusRecordId && focusRecordId > 1 ? focusRecordId - 1 : null)
  const [previous, setPrevious] = useState<(number | null)[]>(focusRecordId && focusRecordId > 1 ? [null] : [])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [attempt, setAttempt] = useState(0)
  useEffect(() => {
    if (!enabled) return
    let live = true
    const controller = new AbortController()
    queueMicrotask(() => { if (live) { setLoading(true); setError(null) } })
    void fetchSavingsPage<T>(collection, cursor, controller.signal).then((next) => { if (scope && (!next.actor_scope || !dailyResponseMatches({...next,actor_scope:next.actor_scope},scope))) throw new ApiRequestError('Private savings history changed.',{status:403}); if (live) setPage(next) }).catch((failure) => { if (live) { setError(message(failure)); setPage(null); if(failure instanceof ApiRequestError&&[401,403,404].includes(failure.status))onDenied?.() } }).finally(() => { if (live) setLoading(false) })
    return () => { live = false; controller.abort() }
  }, [attempt, collection, cursor, enabled, revision, scope, onDenied])
  return <section className="savings-history" aria-label={label}><h4>{label}</h4>{focusRecordId && <p className="savings-caption">Opened at your latest proposal #{focusRecordId}. Previous records returns to earlier history.</p>}{loading && <p role="status">Loading {label.toLowerCase()}…</p>}{error && <div role="alert"><p>{error}</p><button type="button" onClick={() => setAttempt((value) => value + 1)}>Retry history</button></div>}{!loading && page && <>{page.records.length === 0 && <p>No records on this page.</p>}<ol>{page.records.map((record) => <li key={record.id}>{render(record)}</li>)}</ol>{(previous.length > 0 || page.next_cursor !== null) && <div className="savings-pager"><button type="button" disabled={previous.length === 0} onClick={() => { setCursor(previous[previous.length - 1]); setPrevious(previous.slice(0, -1)) }}>Previous records</button><button type="button" disabled={page.next_cursor === null} onClick={() => { setPrevious([...previous, cursor]); setCursor(page.next_cursor) }}>Next records</button></div>}{(previous.length > 0 || page.next_cursor !== null) && <p className="savings-caption">Up to 10 records per page. {page.next_cursor ? 'More records are available.' : 'End of this history.'}</p>}</>}</section>
}
function message(error: unknown) { return error instanceof Error ? error.message : 'This challenge request could not be completed. Please try again.' }
