import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { ApiRequestError, fetchDailyContext, fetchDailyPage } from '../api'
import { type BaselineScope } from '../lib/financialBaseline'
import { savingsDollars, type SavingsIntake } from '../lib/savingsChallenge'
import { dailyApproval, dailyContextMatches, dailyResponseMatches, type DailyCheckIn, type DailyCheckInVersion, type DailyContext, type DailyDay, type DailyInput, type DailyPurchase, type DailyPurchaseDraft, type DailyPurchaseVersion, type DailyScope } from '../lib/dailyChallenge'
import { isDailyActor, readDailyRecovery } from '../lib/dailyRecovery'
import { useDailyMutation, type DailyMutate } from '../lib/useDailyMutation'
import { usePilotDialog } from '../lib/usePilotDialog'
import { DailyHistory, DailyRecordPage } from './DailyRecordPage'
import { DailyPurchaseEditor, PurchaseFactsView } from './DailyPurchaseEditor'
import { DailyReflectionEditor } from './DailyReflectionEditor'
import { ChallengeCheckpoints } from './ChallengeCheckpoint'
import './ChallengeToday.css'
import { participantErrorMessage } from '../lib/participantErrorMessage'

type ChallengeTodayProps = {scope:BaselineScope;cohortId?:number;onClose:()=>void;onStatements:()=>void;onBaseline:()=>void;onPrivacy?:()=>void;initialPurchase?:SavingsIntake|null}
type SpendingState = DailyDay['spending_state']

const isoDate = (iso: string) => new Date(`${iso}T00:00:00Z`)
// "Tue, Oct 21" for a local calendar date; never an ISO date on screen.
function shortDay(iso: string): string {
  return new Intl.DateTimeFormat('en-US', { weekday: 'short', month: 'short', day: 'numeric', timeZone: 'UTC' }).format(isoDate(iso))
}
function dayTitle(iso: string, today: string): string {
  if (iso === today) return `Today, ${shortDay(iso).replace(',', '')}`
  const yesterday = isoDate(today); yesterday.setUTCDate(yesterday.getUTCDate() - 1)
  return iso === yesterday.toISOString().slice(0, 10) ? `Yesterday, ${shortDay(iso).replace(',', '')}` : shortDay(iso)
}
const daysBetween = (from: string, to: string) => Math.round((isoDate(to).getTime() - isoDate(from).getTime()) / 86_400_000)
// After purchases are saved a day reads as spent, even before a check-in is saved.
function effectiveState(day: DailyDay): SpendingState {
  if (day.spending_state === 'no_spend' || day.spending_state === 'spending') return day.spending_state
  return day.approved_purchase_count > 0 ? 'spending' : 'unknown'
}
const STATE_LABELS: Record<SpendingState, string> = { unknown: 'Not checked in yet', spending: 'I spent money', no_spend: 'No spending' }

export function ChallengeToday(props: ChallengeTodayProps) {
  return <ChallengeTodaySession key={`${props.scope.user_id}:${props.scope.household_id}:${props.cohortId ?? 'legacy'}`} {...props}/>
}
function ChallengeTodaySession({scope,cohortId,onClose,onStatements,onBaseline,onPrivacy,initialPurchase}:ChallengeTodayProps) {
  const pinnedEnrollment=useRef<number|undefined>(undefined)
  const staged=useRef<{signature:string;draft:DailyPurchaseDraft}|null>(null)
  const dialog=usePilotDialog(onClose)
  const expected=useMemo(()=>({user_id:scope.user_id,household_id:scope.household_id}),[scope.user_id,scope.household_id])
  const[context,setContext]=useState<DailyContext|null>(null);const[requestedDate,setRequestedDate]=useState<string|undefined>()
  const[loading,setLoading]=useState(true);const[readFailed,setReadFailed]=useState(false);const[error,setError]=useState<string|null>(null);const[denied,setDenied]=useState(false)
  const[attempt,setAttempt]=useState(0);const[section,setSection]=useState<'today'|'checkpoints'>('today')
  const[editing,setEditing]=useState<DailyPurchase|null|undefined>(initialPurchase ? null : undefined)
  const[report,setReport]=useState<SpendingState>('unknown');const[reportReason,setReportReason]=useState('')
  const[categoryName,setCategoryName]=useState('')
  const onDenied=useCallback(()=>setDenied(true),[])
  const refresh=useCallback(()=>{setLoading(true);setAttempt(value=>value+1)},[])
  const actor=useMemo(()=>context&&dailyContextMatches(context,expected,cohortId)?{...expected,enrollment_id:context.enrollment_id,...(context.cohort_id != null ? {cohort_id:context.cohort_id} : {})}:undefined,[context,expected,cohortId])
  const mutation=useDailyMutation(actor,refresh)
  useEffect(()=>{
    const controller=new AbortController();let live=true
    fetchDailyContext(requestedDate,controller.signal).then(result=>{
      if(!live)return
      if(!dailyContextMatches(result,expected,cohortId,pinnedEnrollment.current))throw new ApiRequestError('Private workspace changed.',{status:403})
      if(live){pinnedEnrollment.current=result.enrollment_id;setContext(result);setLoading(false);setReadFailed(false);setError(null);setReport(result.day?effectiveState(result.day):'unknown');setReportReason('')}
    }).catch(failure=>{if(live){setLoading(false);setReadFailed(true);setError(participantErrorMessage(failure, 'Today is unavailable right now.'));if(failure instanceof ApiRequestError&&[401,403,404].includes(failure.status))setDenied(true)}})
    return()=>{live=false;controller.abort()}
  },[requestedDate,attempt,expected,cohortId])
  useEffect(()=>{const focus=()=>refresh();const visible=()=>{if(document.visibilityState==='visible')refresh()};window.addEventListener('focus',focus);document.addEventListener('visibilitychange',visible);return()=>{window.removeEventListener('focus',focus);document.removeEventListener('visibilitychange',visible)}},[refresh])
  const ready=Boolean(context&&actor&&isDailyActor(actor)&&!denied&&!mutation.denied)
  const disabled=mutation.busy||loading||readFailed
  const day=context?.day
  const calendar=context?.calendar
  const savedState=day?effectiveState(day):'unknown'
  const needsReason=Boolean(day?.check_in_version_id)&&report!==day?.spending_state

  async function saveReport(){
    if(!day)return
    if(needsReason&&!reportReason.trim()){setError('Add a short note about what changed for this day.');return}
    setError(null)
    await mutation.mutate('check_in_save',{local_on:day.local_on,spending_state:report,accepted:true,expected_version_id:day.check_in_version_id,expected_head_lock_version:day.check_in_lock_version,reason:reportReason})
  }

  // One tap on "Save purchase" saves the visible values: stage, then approve
  // (accepted: true). A failed approval retries the same staged draft.
  async function savePurchase(input:DailyInput):Promise<boolean>{
    if(!day||!calendar)return false
    const date=input.purchased_on as string
    const sameDay=date===day.local_on
    const purchase=input.disposition!=='void'
    if(purchase&&sameDay&&day.spending_state==='no_spend'){
      const corrected=await mutation.mutate('check_in_save',{local_on:date,spending_state:'spending',accepted:true,expected_version_id:day.check_in_version_id,expected_head_lock_version:day.check_in_lock_version,reason:'Added a purchase in Today'})
      if(!corrected)return false
    }
    const signature=JSON.stringify(input)
    const draft=staged.current?.signature===signature?staged.current.draft:await mutation.mutate('purchase_stage',input) as DailyPurchaseDraft|null
    if(!draft)return false
    staged.current={signature,draft}
    // A future date stays a preview until that day comes.
    if(draft.purchased_on>calendar.local_today)return true
    const approved=await mutation.mutate('purchase_approve',dailyApproval(draft))
    if(!approved){
      // An unconfirmed result keeps the draft so the same approval is replayed;
      // a definite refusal (stale versions) means the next Save stages afresh.
      if(!actor||!readDailyRecovery(actor))staged.current=null
      return false
    }
    staged.current=null
    if(purchase&&sameDay&&!day.check_in_version_id)await mutation.mutate('check_in_save',{local_on:date,spending_state:'spending',accepted:true,expected_version_id:null,expected_head_lock_version:0,reason:''})
    return true
  }

  const dayNumber=calendar&&day?daysBetween(calendar.starts_on,day.local_on)+1:null
  const totalDays=calendar?daysBetween(calendar.starts_on,calendar.ends_on)+1:null
  const purchaseWord=(count:number)=>`${count} ${count===1?'purchase':'purchases'} saved`
  return <div className="daily-overlay"><section ref={dialog} className="daily-dialog" role="dialog" aria-modal="true" aria-labelledby="daily-title" tabIndex={-1}>
    <header><div><h2 id="daily-title">Today</h2>{calendar&&day&&<p className="daily-subtitle">{dayTitle(day.local_on,calendar.local_today)}{dayNumber&&totalDays?` · Day ${dayNumber} of ${totalDays}`:''}</p>}</div><button type="button" onClick={onClose}>Close Today</button></header>
    {(error||mutation.error)&&<p role="alert" className="daily-note">{error??mutation.error}</p>}
    {mutation.pending&&<section aria-label="Earlier daily request"><h3>Check the earlier save first</h3><p>{mutation.pending.working?'Checking…':'We need to confirm whether your last change saved before making another.'}</p><p>Reference number: {mutation.pending.key}</p><div className="daily-actions">{mutation.checkStatus&&<button type="button" disabled={mutation.pending.working} onClick={()=>void mutation.checkStatus?.()}>Check earlier daily result</button>}{mutation.retry&&<button type="button" onClick={()=>void mutation.retry?.()}>Retry the same daily request</button>}</div></section>}
    {denied||mutation.denied?<div><p role="alert">Private daily access is no longer available. Close Today to continue.</p>{onPrivacy&&<button type="button" onClick={onPrivacy}>Privacy & reminders</button>}</div>:<>
      {loading&&<p role="status">Loading today…</p>}
      {readFailed&&<button type="button" onClick={refresh}>Try loading again</button>}
      {ready&&context&&actor&&calendar&&<>
        <nav className="daily-actions daily-tabs" aria-label="Journal sections"><button type="button" aria-pressed={section==='today'} onClick={()=>setSection('today')}>Purchases</button><button type="button" aria-pressed={section==='checkpoints'} onClick={()=>setSection('checkpoints')}>Checkpoints</button></nav>
        {section==='checkpoints'?<ChallengeCheckpoints context={context} scope={actor} refresh={attempt} mutate={mutation.mutate} busy={disabled} onDenied={onDenied} onBaseline={onBaseline}/>:<>
          {day?<>
            <section className="daily-overview" aria-label="Current personal daily report">
              <p className="daily-figure">{day.reported_spend_cents===null?(day.canonical_links_changed?'Spending needs a check':'Not checked in yet'):day.spending_state==='no_spend'&&day.approved_purchase_count===0?'No spending':`${savingsDollars(day.reported_spend_cents)} spent`}</p>
              <p>{day.approved_purchase_count>0?purchaseWord(day.approved_purchase_count):day.spending_state==='no_spend'?'Saved as a no-spend day.':'A day you skip stays unknown, not $0.'}</p>
              {day.canonical_links_changed&&<p className="daily-note">A statement transaction linked to this day changed. Its spending stays unknown until you review it in Statements.</p>}
              {day.no_spend_discrepancy&&<p className="daily-note">This day is saved as no spending but also has a saved purchase. Choose “I spent money” below to fix it.</p>}
            </section>
            {editing===undefined?<button type="button" className="daily-primary" disabled={disabled} onClick={()=>setEditing(null)}>Add a purchase</button>:<DailyPurchaseEditor key={editing?.id??'new'} context={context} scope={actor} purchase={editing??undefined} initialInput={editing===null?initialPurchase:undefined} selectedDate={day.local_on} onSave={savePurchase} busy={disabled} onDone={()=>setEditing(undefined)} onStatements={onStatements} onDenied={onDenied}/>}
            <fieldset disabled={disabled} className="daily-report"><legend className="sr-only">Day check-in</legend>
              <label>How was this day?<select value={report} onChange={event=>setReport(event.target.value as SpendingState)}><option value="unknown">{STATE_LABELS.unknown}</option><option value="spending">{STATE_LABELS.spending}</option><option value="no_spend" disabled={day.approved_purchase_count>0}>{day.approved_purchase_count>0?'No spending (you saved a purchase)':STATE_LABELS.no_spend}</option></select></label>
              {needsReason&&<label>What changed?<input maxLength={500} value={reportReason} onChange={event=>setReportReason(event.target.value)}/></label>}
              <button type="button" disabled={report===day.spending_state} onClick={()=>void saveReport()}>{report===day.spending_state&&day.check_in_version_id?'Day saved':'Save day'}</button>
              {savedState==='spending'&&day.spending_state!=='spending'&&<p className="daily-hint">Your saved purchases already show this day as spent.</p>}
            </fieldset>
          </>:<p className="daily-note">Your challenge starts {shortDay(calendar.starts_on)}. A purchase dated later can be prepared now and saved on that day.</p>}
          {!day&&(editing===undefined?<button type="button" disabled={disabled} onClick={()=>setEditing(null)}>Add a purchase</button>:<DailyPurchaseEditor key={editing?.id??'new'} context={context} scope={actor} purchase={editing??undefined} initialInput={editing===null?initialPurchase:undefined} selectedDate={calendar.starts_on} onSave={savePurchase} busy={disabled} onDone={()=>setEditing(undefined)} onStatements={onStatements} onDenied={onDenied}/>)}
          <label className="daily-date">See another day<input type="date" min={calendar.starts_on} max={calendar.local_today<calendar.ends_on?calendar.local_today:calendar.ends_on} value={day?.local_on??''} disabled={disabled||calendar.phase==='upcoming'} onChange={event=>{setLoading(true);setRequestedDate(event.target.value)}}/><span className="daily-hint">Days follow Guam time.</span></label>
          <DailyRecordPage<DailyPurchase> collection="purchases" scope={actor} refresh={attempt} title="Saved purchases" onDenied={onDenied} render={head=><PurchaseRecord key={`${head.id}:${head.current_version_id}`} head={head} context={context} actor={actor} refresh={attempt} busy={disabled} mutate={mutation.mutate} onDenied={onDenied} onEdit={()=>setEditing(head)}/>}/>
          <PendingPurchases scope={actor} context={context} refresh={attempt} mutate={mutation.mutate} busy={disabled} onDenied={onDenied}/>
          <details><summary>Add your own purchase category (optional)</summary><p>Purchases go under “Everyday spending” unless you pick a category. No budget needed.</p><fieldset disabled={disabled}><legend>New category</legend><label>Category name<input maxLength={80} value={categoryName} onChange={event=>setCategoryName(event.target.value)}/></label><button type="button" disabled={!categoryName.trim()} onClick={()=>void mutation.mutate('category_create',{name:categoryName.trim(),stack_key:'discretionary'}).then(result=>{if(result)setCategoryName('')})}>Create category</button></fieldset></details>
          <button type="button" onClick={onStatements}>Upload or review a receipt in Statements</button>
          <p className="daily-hint">A receipt upload is something to review. It doesn’t add a purchase here by itself.</p>
          <DailyHistory title="Past days">{()=> <DailyRecordPage<DailyCheckIn> collection="check_ins" scope={actor} refresh={attempt} title="Reported days" onDenied={onDenied} render={head=><article key={head.id}><h4>{shortDay(head.local_on)}</h4><p>{STATE_LABELS[head.current_version?.spending_state??'unknown']}</p><DailyHistory title="Changes">{()=> <DailyRecordPage<DailyCheckInVersion> collection="check_in_versions" parentId={head.id} scope={actor} refresh={attempt} title={`${shortDay(head.local_on)} changes`} onDenied={onDenied} render={row=><p key={row.id}>{STATE_LABELS[row.spending_state]} · {row.reason||'No note'}</p>}/> }</DailyHistory></article>}/> }</DailyHistory>
        </>}
      </>}
    </>}
  </section></div>
}
// Purchases started but not saved (for example a save interrupted by a closed
// tab), each named with its amount and day and its own Save button.
function PendingPurchases({scope,context,refresh,mutate,busy,onDenied}:{scope:DailyScope;context:DailyContext;refresh:number;mutate:DailyMutate;busy:boolean;onDenied:()=>void}) {
  const[drafts,setDrafts]=useState<DailyPurchaseDraft[]>([])
  const[cursor,setCursor]=useState<number|null>(null);const[history,setHistory]=useState<Array<number|null>>([]);const[next,setNext]=useState<number|null>(null)
  const[error,setError]=useState(false);const[loading,setLoading]=useState(true);const[attempt,setAttempt]=useState(0)
  useEffect(()=>{const controller=new AbortController();let live=true
    fetchDailyPage<DailyPurchaseDraft>('purchase_drafts',cursor,undefined,controller.signal).then(result=>{if(!dailyResponseMatches(result,scope))throw new ApiRequestError('Private workspace changed.',{status:403});if(live){setDrafts(result.records.filter(draft=>draft.status==='pending'));setNext(result.next_cursor);setLoading(false);setError(false)}}).catch(failure=>{if(live){setLoading(false);setError(true);if(failure instanceof ApiRequestError&&[401,403,404].includes(failure.status))onDenied()}})
    return()=>{live=false;controller.abort()}},[scope,refresh,onDenied,cursor,attempt])
  if(!drafts.length&&!next&&!history.length&&!error)return null
  return <section aria-label="Purchases not saved yet" className="daily-pending"><h3>Purchases to check</h3><p className="daily-hint">They don’t count until you save them.</p>{loading?<p role="status">Loading purchases…</p>:error?<p role="alert">Purchases to check are unavailable. <button type="button" onClick={()=>{setLoading(true);setAttempt(value=>value+1)}}>Try again</button></p>:drafts.map(draft=><PurchaseApproval key={`${draft.id}:${draft.lock_version}:${refresh}`} draft={draft} context={context} mutate={mutate} busy={busy}/>)}{(next!==null||history.length>0)&&<div className="daily-actions"><button type="button" disabled={loading||!history.length} onClick={()=>{setLoading(true);setCursor(history.at(-1)!);setHistory(history.slice(0,-1))}}>Previous purchases to check</button><button type="button" disabled={loading||next===null} onClick={()=>{setLoading(true);setHistory([...history,cursor]);setCursor(next)}}>Next purchases to check</button></div>}</section>
}
function PurchaseApproval({draft,context,mutate,busy}:{draft:DailyPurchaseDraft;context:DailyContext;mutate:DailyMutate;busy:boolean}) {
  const future=draft.purchased_on>context.calendar.local_today
  return <article>{draft.status==='approved'&&<h4>Saved earlier</h4>}<PurchaseFactsView facts={draft} categories={context.categories}/>{draft.reason&&<p>{draft.reason}</p>}{draft.status==='pending'&&<div className="daily-actions">{future&&<p>You can save this on {shortDay(draft.purchased_on)}.</p>}<button type="button" disabled={busy||future} onClick={()=>void mutate('purchase_approve',dailyApproval(draft))}>{draft.disposition==='void'?'Remove purchase':'Save purchase'}</button></div>}</article>
}
function PurchaseRecord({head,context,actor,refresh,busy,mutate,onDenied,onEdit}:{head:DailyPurchase;context:DailyContext;actor:DailyScope;refresh:number;busy:boolean;mutate:DailyMutate;onDenied:()=>void;onEdit:()=>void}) {
  const[feelings,setFeelings]=useState(false);const[history,setHistory]=useState(false)
  const current=head.current_version
  // A purchase with no saved version is listed, by name, under purchases not saved yet.
  if(!current)return null
  return <article><h4>{current?(current.disposition==='void'?'Removed purchase':'Saved purchase'):'Not saved yet'}</h4>{current?<><PurchaseFactsView facts={current} categories={context.categories}/>{current.reason&&<p>{current.reason}</p>}{current.disposition!=='void'&&<button type="button" disabled={busy} onClick={onEdit}>Correct {current.merchant}</button>}</>:<p>This purchase isn’t saved yet, so it isn’t counted.</p>}<details onToggle={event=>{if(event.currentTarget.open)setFeelings(true)}}><summary>Optional feelings for this purchase</summary>{feelings&&<DailyReflectionEditor purchaseId={head.id} scope={actor} refresh={refresh} mutate={mutate} busy={busy} onDenied={onDenied}/>}</details><details onToggle={event=>{if(event.currentTarget.open)setHistory(true)}}><summary>Changes to this purchase</summary>{history&&<DailyRecordPage<DailyPurchaseVersion> collection="purchase_versions" parentId={head.id} scope={actor} refresh={refresh} title="Purchase changes" onDenied={onDenied} render={row=><article key={row.id}><p>{row.reason??'Original purchase'}</p><PurchaseFactsView facts={row} categories={context.categories}/></article>}/>}</details></article>
}
