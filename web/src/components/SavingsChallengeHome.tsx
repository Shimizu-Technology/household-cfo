import { cloneElement, isValidElement, useCallback, useEffect, useId, useMemo, useRef, useState, type FormEvent, type ReactElement, type ReactNode } from 'react'
import { OpeningProgress } from './WorkspaceOpening'
import { ApiRequestError, approveSavingsEntry, approveSavingsPlan, attestSavingsZero, enrollSavingsChallenge, fetchSavingsChallenge, fetchSavingsPage, stageSavingsEntry, stageSavingsPlan, type SavingsCollection } from '../api'
import { savingsDefaultDate, savingsDollars, savingsFundingLabel, savingsFundingOptions, savingsInputCents, savingsInputDollars, type SavingsChallenge, type SavingsEntry, type SavingsEntryVersion, type SavingsEntryDraft, type SavingsFundingSource, type SavingsMutation, type SavingsPage, type SavingsPlanDraft, type SavingsIntake, type SavingsCalendar } from '../lib/savingsChallenge'
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
import { participantErrorMessage } from '../lib/participantErrorMessage'
import { formatDay, formatRange, timeZoneLabel } from '../lib/plainDates'
import { ChallengeExport } from './ChallengeExport'
import { ParticipantPrivacyAccess } from './ParticipantPrivacyAccess'
import { SavingsRowButton, SavingsRowContent } from './SavingsRow'

type RecordRow = SavingsEntry | SavingsEntryVersion | SavingsEntryDraft | SavingsPlanDraft
type Retry = { key: string; perform: (key: string, signal: AbortSignal) => Promise<SavingsMutation<unknown>>; done?: () => void }
type HomeProps = { onOptionalDebt?: () => void; cohortId?: number; evidenceRefreshToken?: number; onReviewEvidence?: (entryVersionId:number)=>void; participantScope?: BaselineScope; onAskMia: () => void; onReviewStatements: () => void; onReviewBaseline?: () => void; onToday?: () => void; onCheckIn?: () => void; privacyAccess?: ReactNode; initialSavingsIntake?: SavingsIntake | null; onEnrollmentKnown?: (enrolled: boolean) => void }
export function SavingsChallengeHome(props: HomeProps) { return <SavingsChallengeHomeBody key={`${props.participantScope?.user_id}:${props.participantScope?.household_id}:${props.cohortId}`} {...props}/> }
function SavingsChallengeHomeBody({ onOptionalDebt, cohortId, evidenceRefreshToken, onAskMia, onReviewStatements, onReviewBaseline, onToday, onCheckIn, privacyAccess, initialSavingsIntake, participantScope, onReviewEvidence, onEnrollmentKnown }: HomeProps) {
  const { assistantName } = useBrand()
  const [planOpen, setPlanOpen] = useState(false)
  const [changingPlan, setChangingPlan] = useState(false)
  const asideId = useId()
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
  const consentStarted = useRef(false)
  const initializedPlan = useRef(false)
  const controllers = useRef(new Set<AbortController>())
  const clearPrivatePlan = useCallback(() => { privateDenied.current=true; sequence.current++;for(const controller of controllers.current)controller.abort();controllers.current.clear();setLoading(false);setParticipation(false);setLateAcceptance(false);setKnownZero(false);setNewMoneyReviewed(false);setIntakeActive(false);setWithdrawal(false);setFunding('new_money_reserved');setComfortable({edited:false,reviewed:false}); setChallenge(null); setReadFailed(true); setError('Private plan access is no longer available.'); setAmount(''); setEffectiveOn(''); setPlanReason(''); setEntryReason(''); setEditingEntry(null); setTarget('500.00'); onEnrollmentKnown?.(false) }, [onEnrollmentKnown])
  const requestErrorRef = useRef<HTMLDivElement>(null)
  const entryHeadingRef = useRef<HTMLHeadingElement>(null)
  const targetHeadingRef = useRef<HTMLHeadingElement>(null)
  const progressHeadingRef = useRef<HTMLHeadingElement>(null)
  const [focusAfterJoin,setFocusAfterJoin] = useState(false)
  const focusJoined = () => setFocusAfterJoin(true)
  useEffect(()=>{if(!focusAfterJoin||!challenge?.enrollment)return;const frame=requestAnimationFrame(()=>{progressHeadingRef.current?.scrollIntoView({block:'start'});progressHeadingRef.current?.focus();setFocusAfterJoin(false)});return()=>cancelAnimationFrame(frame)},[focusAfterJoin,challenge?.enrollment])
  useEffect(() => { consentStarted.current = participation || lateAcceptance }, [participation, lateAcceptance])
  const enrolled = challenge ? Boolean(challenge.enrollment) : null
  useEffect(() => { if (enrolled !== null) onEnrollmentKnown?.(enrolled) }, [enrolled, onEnrollmentKnown])
  const scopeUser = participantScope?.user_id, scopeHousehold = participantScope?.household_id, scopeEnrollment = challenge?.enrollment?.id
  const planScope = useMemo(() => scopeUser && scopeHousehold && scopeEnrollment ? {user_id:scopeUser,household_id:scopeHousehold,enrollment_id:scopeEnrollment} : undefined, [scopeUser,scopeHousehold,scopeEnrollment])
  useEffect(() => { if(participantScope) fencePlanActor(participantScope) }, [participantScope])
  const receivePlan = useCallback((result:SavingsMutation<unknown>) => {sequence.current++;for(const controller of controllers.current)controller.abort();controllers.current.clear();setLoading(false);setChallenge(result.challenge);setReadFailed(false);setError(null);setNotice(result.replayed?'Your earlier plan request was confirmed once.':result.challenge.pending_plan_count?'Your new target is ready. Confirm it below. Spending choices aren’t counted as money set aside.':'Saved. Your target is up to date.');setRevision(value=>value+1);setChangingPlan(false);const record=result.record as {id?:number;status?:string};if(record.status==='pending'&&record.id){setPlanOpen(true);setReviewAnchor({collection:'plan_drafts',id:record.id})}}, [])
  const planMutation = useComfortablePlanMutation(planScope, receivePlan, clearPrivatePlan, revision)
  const scopeCohort = cohortId ?? challenge?.enrollment?.cohort_id
  const homeScope = useMemo(() => scopeUser && scopeHousehold && scopeCohort ? {user_id:scopeUser,household_id:scopeHousehold,cohort_id:scopeCohort} : undefined, [scopeUser,scopeHousehold,scopeCohort])
  const historyScope = useMemo(() => homeScope && scopeEnrollment ? {...homeScope,enrollment_id:scopeEnrollment} : undefined, [homeScope,scopeEnrollment])
  const receiveHome = useCallback((result:SavingsMutation<unknown>,action:HomeSavingsAction) => { sequence.current++;for(const controller of controllers.current)controller.abort();controllers.current.clear();setLoading(false);setChallenge(result.challenge);setReadFailed(false);setError(null);setNotice(result.replayed?'Your earlier request was confirmed once.':homeNotice[action]);setRevision(value=>value+1);const draft=result.record as {id?:number;status?:string;signed_cents?:number};if(draft.status==='pending'&&draft.id){setEntryOpen(true);setReviewAnchor({collection:'entry_drafts',id:draft.id})};setEffectiveOn(current=>current||savingsDefaultDate(result.challenge.calendar));if(action==='enrollment')focusJoined() }, [])
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
      if (lastOffer.current !== offerIdentity) {
        // Changed terms need fresh consent; say so instead of silently clearing checkmarks.
        if (consentStarted.current && lastOffer.current !== null && lastOffer.current !== 'null' && !next.enrollment) setNotice('The joining details were updated. Review them and check the boxes again.')
        setParticipation(false); setLateAcceptance(false); lastOffer.current = offerIdentity
      }
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
      setNotice(result.replayed ? 'Your earlier request was confirmed. It was not added twice.' : (result.record as { status?: string }).status === 'pending' ? 'Check it below, then confirm.' : 'Saved.')
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
      if (expected_plan_version_id && !planReason.trim()) throw new Error('Add a short reason for changing your target.')
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
      if (intakeActive && !withdrawal && savingsFundingOptions.find(option=>option.value===funding)?.eligible && !newMoneyReviewed) throw new Error('Tick the box to confirm this was new money you set aside.')
      const cents = savingsInputCents(amount, editingEntry !== null)
      if (!effectiveOn || effectiveOn < challenge.enrollment!.starts_on || effectiveOn > challenge.enrollment!.ends_on) throw new Error('Choose a date within your 90 days.')
      if (!challenge.calendar || effectiveOn > challenge.calendar.local_today) throw new Error('Add money you’ve already set aside. A future date can’t be saved yet.')
      if (editingEntry && !entryReason.trim()) throw new Error('Add a short reason for the fix.')
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
  const plan = challenge?.accepted_plan ?? null
  const checkIn = onCheckIn ?? onToday
  const pendingPlans = challenge?.pending_plan_count ?? 0
  const pendingEntries = challenge?.pending_entry_count ?? 0
  const next = calendar ? nextCheckpoint(calendar) : null
  const zone = timeZoneLabel(calendar?.time_zone ?? offer?.time_zone)
  const reported = projection?.reported_cents ?? null
  const excluded = projection?.excluded_entry_count ?? 0
  const matched = projection?.evidence_supported_cents ?? 0
  const suggested = challenge?.suggested_target_cents ? wholeDollars(challenge.suggested_target_cents) : '$500'
  const fundingEligible = savingsFundingOptions.find((option) => option.value === funding)?.eligible
  const exportScope = challenge?.enrollment && participantScope && scopeCohort ? participantScope : null
  const privacyRow = isValidElement(privacyAccess) && privacyAccess.type === ParticipantPrivacyAccess ? cloneElement(privacyAccess as ReactElement<{ variant?: 'row'; description?: string }>, { variant: 'row', description: 'Who can see what, and your reminders' }) : privacyAccess
  function openAside() { setEntryOpen(true); requestAnimationFrame(() => { entryHeadingRef.current?.scrollIntoView?.({ block: 'start' }); entryHeadingRef.current?.focus() }) }
  function openTarget() { setPlanOpen(true); requestAnimationFrame(() => { targetHeadingRef.current?.scrollIntoView?.({ block: 'center' }); targetHeadingRef.current?.focus() }) }
  const planHistory = challenge?.enrollment ? <SavingsHistory<SavingsPlanDraft> scope={historyScope} onDenied={clearPrivatePlan} key={reviewAnchor?.collection === 'plan_drafts' ? `plan:${reviewAnchor.id}` : 'plan'} focusRecordId={reviewAnchor?.collection === 'plan_drafts' ? reviewAnchor.id : undefined} collection="plan_drafts" label="Target changes" hideWhenEmpty revision={revision} enabled={!busy} render={(draft) => <>
    <p><strong>{draft.target_cents === null ? 'Choose my target later' : savingsDollars(draft.target_cents)}</strong> · {statusWord(draft.status)}</p>
    {draft.reason && <p>{draft.reason}</p>}
    {draft.status === 'pending' && <SavingsPlanApprovalReview key={`${draft.id}:${draft.lock_version}:${revision}`} draft={draft} disabled={busy || loading || readFailed || planMutation.needsRefresh || Boolean(planMutation.pending && !(planMutation.freshAction?.action === 'plan_approve' && planMutation.freshAction.draftId === draft.id)) || retry !== null || homeMutation.pending !== null} onApprove={() => {if(homeMutation.isPending())return;const input={accepted:true as const,expected_draft_lock_version:draft.lock_version,expected_plan_version_id:draft.base_plan_version_id};if(participantScope)void planMutation.perform('plan_approve',input,draft.id);else stage((key,signal)=>approveSavingsPlan(draft.id,input,key,signal))}}/>}
  </>} /> : null
  // Only one pending target can be confirmed. Once it exists, confirm it (or
  // explicitly choose to replace it) instead of preparing a duplicate.
  const showPlanForm = pendingPlans === 0 || changingPlan || Boolean(planMutation.pending)
  return <section className="savings-home screen-grid" aria-label="Savings challenge">
    <div className="screen-heading"><h2 data-page-heading tabIndex={-1}>Your savings challenge</h2>{loading && challenge && <p className="savings-refreshing" role="status">Loading your challenge…</p>}</div>
    {error && <div className="savings-error" role="alert" tabIndex={-1} ref={requestErrorRef}><p>{error}</p>{retry ? <><p>We couldn’t confirm that this saved. Try again before making another change.</p><button type="button" disabled={busy} onClick={() => void mutate(retry)}>Retry same request</button></> : <button type="button" disabled={busy} onClick={() => {privateDenied.current=false;void refresh()}}>Refresh challenge</button>}</div>}
    <HomeSavingsRequestRecovery state={homeMutation} onFresh={prepareHomeFresh}/>
    {freshHome?.action==='entry_stage'&&freshHome.entryId&&<p role="status">Open “Your records & corrections” below and choose Fix record #{freshHome.entryId} to finish. Only that record can be changed right now.</p>}
    {(planMutation.pending || planMutation.error) && <PlanRequestRecovery state={planMutation} onRefresh={()=>void refresh()}/>}
    {notice && <p className="savings-notice" role="status">{notice}</p>}
    {readFailed && challenge && <p role="status">Showing your last saved results. We couldn’t refresh them, so refresh before making changes.</p>}
    {/* Background refreshes keep the current view steady; only the first read shows progress. */}
    {loading && !challenge && <OpeningProgress status="Loading your challenge…" />}
    {!challenge && !loading && <p>Your challenge is unavailable right now. Nothing has changed.</p>}

    {challenge && !challenge.enrollment && <article className="panel savings-enrollment" aria-label="Join the challenge">
      <h3>Join the 90-day savings challenge</h3>
      <p>Set aside new money at your own pace for 90 days, toward {suggested} or a target you choose.</p>
      {offer ? <>
        <p className="savings-join-dates"><strong>Your 90 days: {offer.personal_starts_on && offer.personal_ends_on ? formatRange(offer.personal_starts_on, offer.personal_ends_on).split(' – ').map((part, index) => <span key={index}>{index > 0 && ' – '}<span className="savings-nowrap">{part}</span></span>) : 'dates not set yet'}</strong><span>{offer.cohort_label}</span></p>
        <ul className="savings-terms">
          <li>You choose your target after joining: {suggested}, a smaller amount, or decide later.</li>
          <li>We keep a record of the savings and choices you confirm. Joining doesn’t move money, connect a bank, or need a credit card or a full budget.</li>
          <li>Statements are optional and reviewed separately. Joining doesn’t give your coach access to your statements.</li>
          <li>Your spot in the group is confirmed when you join.</li>
        </ul>
        <label className="savings-check"><input type="checkbox" checked={participation} disabled={actionLocked('enrollment')} onChange={(event) => setParticipation(event.target.checked)} />I have read this notice and want to join.</label>
        {offer.late_start_acceptance_required && <label className="savings-check"><input type="checkbox" checked={lateAcceptance} disabled={actionLocked('enrollment')} onChange={(event) => setLateAcceptance(event.target.checked)} />I understand my 90 days start later than the group’s, on {formatDay(offer.personal_starts_on)}, and run through {formatDay(offer.personal_ends_on, { year: true })}.</label>}
        <button type="button" className="savings-primary" disabled={actionLocked('enrollment') || !offer.accepting_enrollments || !participation || Boolean(offer.late_start_acceptance_required && !lateAcceptance)} onClick={() => homeStage('enrollment',(key, signal) => enrollSavingsChallenge({ participation_accepted: true, policy_version: offer.policy_version, late_start_accepted: lateAcceptance, expected_acceptance_digest: offer.acceptance_digest }, key, signal))}>Accept and join</button>
        {!offer.accepting_enrollments && <p role="status">This group isn’t taking new members right now.</p>}
      </> : <p>We couldn’t load the joining details. Refresh to see them before joining.</p>}
    </article>}

    {challenge?.enrollment && <>
      <article className="savings-summary" aria-label="Approved savings progress">
        <h3 ref={progressHeadingRef} tabIndex={-1}>Set aside so far</h3>
        <p className={reported === null ? 'savings-total savings-total--words' : 'savings-total'}>{reported === null ? 'Nothing set aside yet' : savingsDollars(reported)}</p>
        <p className="savings-target-line">{!plan
          ? <><span>No target yet</span> — <button type="button" className="savings-link" onClick={openTarget}>choose one</button></>
          : plan.target_cents === null
            ? <><span>You’ll choose a target later</span> — <button type="button" className="savings-link" onClick={openTarget}>choose now</button></>
            : <>of {savingsDollars(plan.target_cents)} target{projection?.progress_basis_points != null ? ` · ${Math.floor(projection.progress_basis_points / 100)}%` : ''}</>}</p>
        {projection?.progress_basis_points != null && <progress className="savings-bar" aria-label="Progress toward your target" max={10000} value={projection.progress_basis_points} />}
        {calendar && <p className="savings-day-line">{dayLine(calendar, next)}</p>}
        {projection && !projection.reporting_known && <p className="savings-caption">We don’t assume $0. Add money when you set it aside, or tell us if there’s nothing to add.</p>}
        {/* Withdrawals use up matched money first, so the matched part can be smaller than any one record's match. */}
        {matched > 0 && <p className="savings-caption">{projection?.withdrawal_cents ? `After the money you took out, ${savingsDollars(matched)} of what’s left is matched to a statement.` : `${savingsDollars(matched)} of this is matched to a statement.`} That’s included above, not extra.</p>}
        {excluded > 0 && <p className="savings-caption">{excluded === 1 ? '1 record isn’t counted because it wasn’t' : `${excluded} records aren’t counted because they weren’t`} new money (for example, money you already had or borrowed).</p>}
        {reported !== null && reported < 0 && <p className="savings-caption">You’ve taken out more than you set aside, so the bar stays empty.</p>}
        <div className="savings-actions">
          {checkIn && <button type="button" className="savings-primary" onClick={(event) => { event.currentTarget.focus(); checkIn() }}>Check in for today</button>}
          <button type="button" className="savings-secondary" aria-expanded={entryOpen} aria-controls={asideId} onClick={() => { if (entryOpen) setEntryOpen(false); else openAside() }}>I set money aside{pendingEntries > 0 && <span className="savings-badge"> · {pendingEntries} to confirm</span>}</button>
        </div>
      </article>

      <section id={asideId} className={entryOpen ? 'savings-aside panel' : 'savings-aside panel is-collapsed'} aria-label="Add money you set aside">
        <h3 ref={entryHeadingRef} tabIndex={-1}>{editingEntry ? `Fix record #${editingEntry.id}` : 'Add money you set aside'}</h3>
        <p>This is your own record of money you’ve already put aside. It doesn’t move money and isn’t checked with your bank. Paying down debt, or moving money you already had, doesn’t count as new.</p>
        <form onSubmit={submitEntry}><fieldset disabled={entryFormLocked || !elapsed}>
          <label>Amount in US dollars<input inputMode="decimal" value={amount} onChange={(event) => { setNewMoneyReviewed(false); setAmount(event.target.value) } } required /></label>
          <label className="savings-check"><input type="checkbox" checked={withdrawal} onChange={(event) => { setNewMoneyReviewed(false); setWithdrawal(event.target.checked) }} />I took this money out of my challenge savings</label>
          <label>Date you set it aside or took it out<input type="date" value={effectiveOn} min={challenge.enrollment.starts_on} max={calendar?.local_today && calendar.local_today < challenge.enrollment.ends_on ? calendar.local_today : challenge.enrollment.ends_on} onChange={(event) => { setNewMoneyReviewed(false); setEffectiveOn(event.target.value) } } required /></label>
          {!withdrawal && <label>Where did this money come from?<select value={funding} onChange={(event) => { setNewMoneyReviewed(false); setFunding(event.target.value as SavingsFundingSource) }}>{savingsFundingOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</select></label>}
          {!withdrawal && !fundingEligible && <p className="savings-excluded">This won’t count toward your total, but it stays in your record.</p>}
          {editingEntry && <label>Reason for correction<textarea maxLength={500} value={entryReason} onChange={(event) => setEntryReason(event.target.value)} required /></label>}
          {intakeActive && <><p>{assistantName} filled this in from your chat. Check the amount, date and where the money came from. Nothing counts until you confirm.</p>{!withdrawal && fundingEligible && <label className="savings-check"><input type="checkbox" checked={newMoneyReviewed} onChange={event=>setNewMoneyReviewed(event.target.checked)}/>This was new money I set aside after expenses, not borrowed or money I already had.</label>}</>}
          <div className="savings-form-actions"><button type="submit" className="savings-action" disabled={intakeActive && !withdrawal && Boolean(fundingEligible) && !newMoneyReviewed}>Review savings record</button>{editingEntry && <button type="button" onClick={() => { setEditingEntry(null); setAmount(''); setEntryReason('') }}>Cancel correction</button>}</div>
        </fieldset></form>
        {!elapsed && <p>You can add money once your 90 days start.</p>}
        {projection && !projection.reporting_known && elapsed && <details className="savings-zero"><summary>Nothing to add?</summary><section aria-label="Confirm nothing set aside"><p>If you’re not sure, leave it for now. If you know you haven’t set aside or taken out any new money through {formatDay(projection.cutoff_on)}, you can say so.</p><label className="savings-check"><input type="checkbox" checked={knownZero} disabled={actionLocked('zero_attest')} onChange={(event) => setKnownZero(event.target.checked)} />I know I haven’t set aside or taken out any new money through this date.</label><button type="button" className="savings-action" disabled={actionLocked('zero_attest') || !knownZero} onClick={() => homeStage('zero_attest',(key, signal) => attestSavingsZero({ known_zero: true, cutoff_on: projection.cutoff_on, expected_enrollment_lock_version: challenge.enrollment!.lock_version }, key, signal), () => setKnownZero(false))}>Confirm nothing set aside</button></section></details>}
        <SavingsHistory<SavingsEntryDraft> scope={historyScope} onDenied={clearPrivatePlan} key={reviewAnchor?.collection === 'entry_drafts' ? `entry:${reviewAnchor.id}` : 'entry'} focusRecordId={reviewAnchor?.collection === 'entry_drafts' ? reviewAnchor.id : undefined} collection="entry_drafts" label="Recent entries" hideWhenEmpty revision={revision} enabled={!busy} render={(draft) => <>
          <p><strong>{savingsDollars(draft.signed_cents)}</strong> · {formatDay(draft.effective_on)} · {statusWord(draft.status)}</p>
          <p>{savingsFundingLabel(draft.funding_source)}</p>
          {draft.reason && <p>{draft.reason}</p>}
          {draft.status === 'pending' && <><p>Your total doesn’t change until you confirm.</p><button type="button" className="savings-action" disabled={actionLocked('entry_approve',draft.id) || !calendar || draft.effective_on > calendar.local_today} onClick={() => homeStage('entry_approve',(key, signal) => approveSavingsEntry(draft.id, { accepted: true, expected_draft_lock_version: draft.lock_version, expected_version_id: draft.base_version_id, expected_entry_lock_version: draft.base_entry_lock_version }, key, signal),undefined,draft.id)}>Confirm savings record #{draft.id}</button>{(!calendar || draft.effective_on > calendar.local_today) && <p>You can confirm this on or after {formatDay(draft.effective_on)}.</p>}</>}
        </>} />
      </section>

      {calendar && <section className="savings-checkpoints" aria-label="Personal challenge calendar">
        <ol>{(['30', '60', '90'] as const).map((day) => <li key={day} aria-current={next?.day === day ? 'step' : undefined} className={next?.day === day ? 'is-current' : undefined}><strong>Day {day}</strong><span>{formatDay(calendar.checkpoints[day])}</span></li>)}</ol>
        {onCheckIn && onToday && <button type="button" className="savings-link" onClick={(event) => { event.currentTarget.focus(); onToday() }}>Open today’s record and check-ins</button>}
      </section>}
    </>}

    {/* Wait for the first read so rows don't flash in before the summary. */}
    {(challenge || !loading) && <><div className="savings-rows">
      {challenge?.enrollment && <details className="savings-row-group" open={planOpen} onToggle={event => setPlanOpen(event.currentTarget.open)}>
        <summary className="savings-row"><SavingsRowContent label="Your target & spending choices" count={pendingPlans ? `${pendingPlans} to review` : undefined} description={!plan ? `Choose ${suggested} or an amount that fits you` : plan.target_cents === null ? 'Choose a target whenever you’re ready' : `Your target is ${savingsDollars(plan.target_cents)}. Change it or add spending choices.`} /></summary>
        <section className="savings-row-body" aria-label="Savings target plan">
          <h3 ref={targetHeadingRef} tabIndex={-1}>{plan ? 'Change your target' : 'Choose your target'}</h3>
          <p>{suggested} is the suggested target. You can pick a smaller amount, or decide later.</p>
          {plan && <section aria-label="Accepted spending choices"><h4>Your current plan</h4><ComfortablePlanSummary plan={plan}/></section>}
          {!showPlanForm && <>{planHistory}<p>Want a different target? <button type="button" className="savings-link" onClick={() => setChangingPlan(true)}>Change it instead</button></p></>}
          {showPlanForm && <form onSubmit={submitPlan}><fieldset disabled={planFormLocked}>
            <label>Target in US dollars<input inputMode="decimal" value={target} disabled={postponed} onChange={(event) => setTarget(event.target.value)} /></label>
            <label className="savings-check"><input type="checkbox" checked={postponed} onChange={(event) => setPostponed(event.target.checked)} />I will choose my target later</label>
            {plan && <label>Reason for target change<textarea maxLength={500} value={planReason} onChange={(event) => setPlanReason(event.target.value)} required /></label>}
            <ComfortablePlanChoices key={`${participantScope?.user_id}:${participantScope?.household_id}:${challenge.enrollment.id}`} acceptedPlan={plan} scope={participantScope} disabled={planFormLocked} freshness={revision} onChange={setComfortable} onDenied={clearPrivatePlan} onBaseline={onReviewBaseline}/>
            {comfortable.error && <p className="savings-caption">{comfortable.error}</p>}
            <div className="savings-form-actions"><button type="submit" className="savings-action" disabled={Boolean(planMutation.pending?.working) || (comfortable.edited && (!comfortable.reviewed || Boolean(comfortable.error)))}>Review target plan</button>{changingPlan && <button type="button" onClick={() => setChangingPlan(false)}>Keep the target waiting below</button>}</div>
          </fieldset></form>}
          {showPlanForm && planHistory}
        </section>
      </details>}

      {challenge?.enrollment && <details className="savings-row-group" open={historyOpen} onToggle={event => setHistoryOpen(event.currentTarget.open)}>
        <summary className="savings-row"><SavingsRowContent label="Your records & corrections" description="See what you’ve saved and fix a mistake" /></summary>
        <section className="savings-row-body" aria-label="Approved savings history">
          <p>A fix doesn’t change your total until you confirm it.</p>
          <SavingsHistory<SavingsEntry> scope={historyScope} onDenied={clearPrivatePlan} key={freshHome?.entryId??'entries'} focusRecordId={freshHome?.entryId} collection="entries" label="Savings history" revision={revision} enabled={!busy} render={(entry) => {
            const version = entry.current_approved_version
            if (!version) return <p>Record #{entry.id} is waiting for you to confirm it under “I set money aside”.</p>
            const match = matchWords(version)
            return <>
              <p><strong>{savingsDollars(version.signed_cents)}</strong> · {formatDay(version.effective_on)}{version.version_number > 1 ? ` · fixed (version ${version.version_number})` : ''}</p>
              <p>{savingsFundingLabel(version.funding_source)}{match ? ` · ${match}` : ''}</p>
              <div className="savings-form-actions">
                {onReviewEvidence && version.signed_cents > 0 && savingsFundingOptions.some(option=>option.value===version.funding_source&&option.eligible) && <button type="button" disabled={locked} onClick={()=>onReviewEvidence(version.id)}>{version.evidence_status === 'not_linked' ? 'Match to a statement' : 'Review statement match'}</button>}
                <button type="button" disabled={actionLocked('entry_stage',undefined,entry.id)} onClick={() => editEntry(entry)}>Fix record #{entry.id}</button>
              </div>
            </>
          }} />
          {onReviewEvidence && <details className="savings-versions"><summary>Earlier versions of your records</summary><p>Only the latest version of each record counts. You can remove an old statement match so that money can be matched to another record.</p><SavingsHistory<SavingsEntryVersion> scope={historyScope} onDenied={clearPrivatePlan} collection="entry_versions" label="Earlier versions" revision={revision} enabled={!busy} render={(version)=><><p><strong>{savingsDollars(version.signed_cents)}</strong> · {formatDay(version.effective_on)} · version {version.version_number}</p><p>{savingsFundingLabel(version.funding_source)}{version.reason ? ` · ${version.reason}` : ''}</p>{version.signed_cents>0&&savingsFundingOptions.some(option=>option.value===version.funding_source&&option.eligible)&&<button type="button" disabled={locked} onClick={()=>onReviewEvidence(version.id)}>Review statement match for version {version.version_number}</button>}</>}/></details>}
        </section>
      </details>}

      <details className="savings-row-group">
        <summary className="savings-row"><SavingsRowContent label="Statements & spending snapshot (optional)" description="Upload statements or see where your money goes" /></summary>
        <div className="savings-row-body">
          <p>Optional. You can do the whole challenge without statements, a spending snapshot or a full budget.</p>
          <div className="savings-form-actions"><button type="button" onClick={onReviewStatements}>Review or upload statements</button>{onReviewBaseline && <button type="button" onClick={(event) => { event.currentTarget.focus(); onReviewBaseline?.() }}>Open your spending snapshot</button>}</div>
        </div>
      </details>

      {onOptionalDebt && challenge?.enrollment && <div className="savings-row-group"><SavingsRowButton label="Card & debt review (optional)" description="Compare cards if it helps. Paying debt isn’t counted as saving." onClick={onOptionalDebt} /></div>}
      {privacyRow && <div className="savings-row-group">{privacyRow}</div>}
      {exportScope && scopeCohort && <ChallengeExport scope={exportScope} cohortId={scopeCohort} variant="row" />}
    </div>
    <p className="savings-footnote">{zone && `Dates follow ${zone}. `}Questions? <button type="button" className="savings-link" onClick={onAskMia}>Ask {assistantName}</button></p></>}
  </section>
}
function SavingsHistory<T extends RecordRow>({ collection, label, revision, enabled, render, focusRecordId, scope, onDenied, hideWhenEmpty }: { scope?: DailyScope; onDenied?: () => void; focusRecordId?: number; collection: SavingsCollection; label: string; revision: number; enabled: boolean; render: (record: T) => ReactNode; hideWhenEmpty?: boolean }) {
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
  // Lists that only matter once something exists (recent entries, target changes) stay out of the way until then.
  if (hideWhenEmpty && !error && previous.length === 0 && (page ? page.records.length === 0 && page.next_cursor === null : loading)) return null
  return <section className="savings-history" aria-label={label}><h4>{label}</h4>{focusRecordId && previous.length > 0 && <p className="savings-caption">Showing your newest entry first. Use Previous records for older ones.</p>}{loading && <p role="status">Loading {label.toLowerCase()}…</p>}{error && <div role="alert"><p>{error}</p><button type="button" onClick={() => setAttempt((value) => value + 1)}>Retry history</button></div>}{!loading && page && <>{page.records.length === 0 && <p>Nothing here yet.</p>}<ol>{page.records.map((record) => <li key={record.id}>{render(record)}</li>)}</ol>{(previous.length > 0 || page.next_cursor !== null) && <div className="savings-pager"><button type="button" disabled={previous.length === 0} onClick={() => { setCursor(previous[previous.length - 1]); setPrevious(previous.slice(0, -1)) }}>Previous records</button><button type="button" disabled={page.next_cursor === null} onClick={() => { setPrevious([...previous, cursor]); setCursor(page.next_cursor) }}>Next records</button></div>}</>}</section>
}
const homeNotice: Record<HomeSavingsAction, string> = { enrollment: 'You’re in. Welcome to the challenge.', entry_stage: 'Check it below, then confirm to add it to your total.', entry_approve: 'Saved. Your total is up to date.', zero_attest: 'Saved. Nothing set aside so far.' }
function statusWord(status: string) { return status === 'pending' ? 'Waiting for you to confirm' : status === 'approved' ? 'Saved' : 'Not used' }
function wholeDollars(cents: number) { return cents % 100 === 0 ? `$${new Intl.NumberFormat('en-US').format(cents / 100)}` : savingsDollars(cents) }
function matchWords(version: SavingsEntryVersion) {
  if (version.evidence_status === 'linked') return `${savingsDollars(version.evidence_supported_cents)} matched to a statement`
  if (version.evidence_status === 'stale') return 'Statement match needs another look'
  if (version.evidence_status === 'revoked') return 'Statement match removed'
  return ''
}
function nextCheckpoint(calendar: SavingsCalendar): { day: '30' | '60' | '90'; date: string } | null {
  for (const day of ['30', '60', '90'] as const) { const date = calendar.checkpoints[day]; if (date && date >= calendar.local_today) return { day, date } }
  return null
}
function dayLine(calendar: SavingsCalendar, next: ReturnType<typeof nextCheckpoint>): ReactNode {
  if (calendar.phase === 'upcoming') return `Your 90 days start ${formatDay(calendar.starts_on)}`
  if (calendar.phase === 'window_ended') return `Your 90 days ended ${formatDay(calendar.ends_on)}. You can still add money you set aside before then.`
  const day = calendar.day ? `Day ${calendar.day} of 90` : 'Your 90 days are underway'
  if (!next) return day
  return next.date === calendar.local_today ? `${day} · your Day ${next.day} check-in is today` : <>{day} · next check-in Day {next.day} on <span className="savings-nowrap">{formatDay(next.date)}</span></>
}
function message(error: unknown) { return participantErrorMessage(error, 'This challenge request could not be completed. Please try again.') }
