import { useEffect, useMemo, useRef, useState } from 'react'
import { fetchDailyContext, fetchDailyPage, fetchSavingsChallenge } from '../api'
import { dailyApproval, dailyContextMatches, dailyResponseMatches, type CheckpointSnapshot, type DailyCheckpoint, type DailyCheckpointDraft, type DailyScope } from '../lib/dailyChallenge'
import type { BaselineScope } from '../lib/financialBaseline'
import { bibaSentence } from '../lib/bibaSentence'
import { formatDay } from '../lib/plainDates'
import { savingsDollars, savingsTargetDollars } from '../lib/savingsChallenge'
import { readDailyRecovery } from '../lib/dailyRecovery'
import { useDailyMutation } from '../lib/useDailyMutation'
import { BibaCard } from './BibaCard'
import './MiaDailyCheckIn.css'

type Day = 30 | 60 | 90
type Props = { actor: BaselineScope; cohortId: number; refreshKey?: number; onDone: () => void; onOpenCheckpoints: () => void }

const freshKeys = () => ({ stage: crypto.randomUUID(), approve: crypto.randomUUID() })
const dismissKey = (actor: BaselineScope, day: Day, localToday: string) => `hcfo-checkpoint-card:${actor.user_id}:${actor.household_id}:${day}:${localToday}`
const readDismissed = (key: string) => { try { return window.sessionStorage.getItem(key) === '1' } catch { return false } }
const writeDismissed = (key: string) => { try { window.sessionStorage.setItem(key, '1') } catch { /* private mode: the card just comes back */ } }

// Day 30, 60 or 90, offered in the chat once it is due. She looks at what she
// set aside and noticed, then approves it. Nothing is saved before that, and
// fixing a past review stays on the Checkpoints screen.
export function MiaCheckpointCard({ actor, cohortId, refreshKey = 0, onDone, onOpenCheckpoints }: Props) {
  const [due, setDue] = useState<{ day: Day; scope: DailyScope; localToday: string } | null>(null)
  const [dismissed, setDismissed] = useState(false)
  const [draft, setDraft] = useState<DailyCheckpointDraft | null>(null)
  const [finished, setFinished] = useState(false)
  const [finalDone, setFinalDone] = useState(false)
  const [checked, setChecked] = useState(false)
  const [working, setWorking] = useState(false)
  const [error, setError] = useState('')
  const [stale, setStale] = useState(false)
  const [celebrate, setCelebrate] = useState<CheckpointSnapshot | null>(null)
  // New request keys for each milestone and each fresh look; kept only to retry the same request after a dropped connection.
  const keys = useRef(freshKeys())
  const milestone = useRef<Day | null>(null)
  const heading = useRef<HTMLHeadingElement>(null)
  const card = useRef<HTMLElement>(null)
  const mutation = useDailyMutation(due?.scope, () => undefined)

  useEffect(() => {
    const controller = new AbortController()
    Promise.all([fetchSavingsChallenge(controller.signal), fetchDailyContext(undefined, controller.signal)]).then(([challenge, context]) => {
      if (controller.signal.aborted || !challenge.enrollment || !dailyContextMatches(context, actor, cohortId, challenge.enrollment.id)) return
      const day = challenge.timeline?.checkpoints_due?.[0]
      if (day !== 30 && day !== 60 && day !== 90) { setDue(null); return }
      const localToday = context.calendar.local_today
      // A different milestone starts clean: its own request keys, its own checkbox.
      if (milestone.current !== day) { milestone.current = day; keys.current = freshKeys(); setDraft(null); setChecked(false); setFinalDone(false); setError(''); setStale(false) }
      setDismissed(readDismissed(dismissKey(actor, day, localToday)))
      setDue({ day, localToday, scope: { ...actor, enrollment_id: context.enrollment_id, ...(context.cohort_id != null ? { cohort_id: context.cohort_id } : {}) } })
    }).catch(() => undefined)
    return () => controller.abort()
  }, [actor, cohortId, refreshKey])

  const snapshot = draft?.snapshot
  // Keep the card in view as it grows from the offer to the look back.
  const shown = Boolean(due) && !dismissed && !finished
  useEffect(() => { if (shown) card.current?.scrollIntoView?.({ block: 'nearest' }) }, [shown, snapshot])
  const lines = useMemo(() => snapshot ? facts(snapshot) : [], [snapshot])
  if (celebrate) {
    return <BibaCard title={celebrate.milestone_day === 90 && celebrate.final_confirmation_status !== 'confirmed' ? 'Biba! Your Day 90 review is saved.' : `Biba! Day ${celebrate.milestone_day} is done.`} actionLabel="Keep going" onAction={() => { setCelebrate(null); setDue(null); onDone() }}>{bibaSentence(celebrate)}</BibaCard>
  }
  if (!due || dismissed || finished) return null

  const { day, scope } = due
  const busy = working || mutation.busy
  const shownError = error || mutation.error || ''

  async function look() {
    if (busy) return
    setWorking(true); setError('')
    try {
      const heads = await fetchDailyPage<DailyCheckpoint>('checkpoints', null)
      if (!dailyResponseMatches(heads, scope) || heads.next_cursor !== null) throw new Error('We couldn’t check your earlier reviews. Nothing changed.')
      const head = heads.records.find(row => row.milestone_day === day)
      if (head?.current_version) { setFinished(true); onDone(); return }
      const record = await mutation.mutate('checkpoint_stage', { milestone_day: day, expected_version_id: head?.current_version_id ?? null, expected_head_lock_version: head?.lock_version ?? 0, reason: '', final_confirmation_accepted: day === 90 && finalDone }, undefined, keys.current.stage) as DailyCheckpointDraft | null
      if (record) showDraft(record)
      else if (!readDailyRecovery(scope)) keys.current = freshKeys()
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : 'We couldn’t prepare that. Nothing changed.')
    } finally {
      setWorking(false)
    }
  }

  function showDraft(record: DailyCheckpointDraft) {
    setDraft(record); setStale(false); setChecked(false)
    requestAnimationFrame(() => heading.current?.focus())
  }

  function celebrateSaved(saved: DailyCheckpointDraft) {
    setCelebrate(saved.snapshot); setDraft(null); setChecked(false); setFinalDone(false); setStale(false)
    keys.current = freshKeys()
  }

  async function approve() {
    if (!draft || busy || !checked) return
    setWorking(true); setError('')
    try {
      const result = await mutation.mutate('checkpoint_approve', dailyApproval(draft), undefined, keys.current.approve)
      if (result) celebrateSaved(draft)
      // Refused for good (for example, something else changed her savings since the preview): the preview is out of date.
      else if (!readDailyRecovery(scope)) setStale(true)
    } finally {
      setWorking(false)
    }
  }

  // A fresh preview of the same milestone, with new request keys so the server builds it again instead of replaying the old one.
  function lookAgain() {
    if (busy) return
    keys.current = freshKeys()
    setDraft(null); setChecked(false); setStale(false); setError('')
    void look()
  }

  // The connection dropped mid-request: check whether it saved, or send the very same request again. Neither saves twice.
  async function retrySame() {
    const action = mutation.pending?.action
    const result = await mutation.retry?.()
    if (!result) return
    if (action === 'checkpoint_stage') showDraft(result as DailyCheckpointDraft)
    else if (action === 'checkpoint_approve' && draft) celebrateSaved(draft)
  }

  const recovery = mutation.pending && !mutation.pending.working && <div className="mia-card-recovery" role="status">
    <p>I’m not sure that went through. Nothing is lost, and nothing will save twice.</p>
    <div className="mia-daily-actions">
      {mutation.checkStatus && <button type="button" className="secondary-button" onClick={() => void mutation.checkStatus?.()}>Check if it saved</button>}
      {mutation.retry && <button type="button" className="mia-daily-save" onClick={() => void retrySame()}>Try again</button>}
    </div>
  </div>

  function notNow() {
    writeDismissed(dismissKey(actor, day, due!.localToday))
    setDismissed(true)
  }

  if (!draft || !snapshot) {
    return <section ref={card} className="mia-daily-card mia-action-card" aria-label={`Day ${day} review`} aria-busy={busy}>
      <h3 ref={heading} tabIndex={-1}>Day {day} is ready to look back on</h3>
      <p>I can show what you set aside and what you noticed through {formatDay(scope && due.localToday, { year: false })}, next to your target. Nothing is saved until you approve it.</p>
      {day === 90 && <label className="mia-card-check"><input type="checkbox" checked={finalDone} disabled={busy} onChange={event => setFinalDone(event.target.checked)} /><span>I’m finished reporting my 90 days. If you’re still checking, leave this blank; your saved amounts still count.</span></label>}
      {shownError && <p role="alert">{shownError}</p>}
      {recovery}
      <div className="mia-daily-actions">
        <button type="button" className="mia-daily-save" disabled={busy} onClick={() => void look()}>{busy ? 'Getting it ready…' : `Look at Day ${day}`}</button>
        <button type="button" className="secondary-button" disabled={busy} onClick={onOpenCheckpoints}>Open in Checkpoints</button>
        <button type="button" className="mia-daily-dismiss" disabled={busy} onClick={notNow}>Not now</button>
      </div>
    </section>
  }

  return <section ref={card} className="mia-daily-card mia-action-card" aria-label={`Day ${day} review`} aria-busy={busy}>
    <h3 ref={heading} tabIndex={-1}>Day {day}: here’s your look back</h3>
    <p className="mia-daily-hint">Through {formatDay(snapshot.cutoff_on, { year: true })}, from the amounts and check-ins you already saved.</p>
    <dl className="mia-card-facts">{lines.map(([term, value]) => <div key={term}><dt>{term}</dt><dd>{value}</dd></div>)}</dl>
    <label className="mia-card-check"><input type="checkbox" checked={checked} disabled={busy} onChange={event => setChecked(event.target.checked)} /><span>I checked the dates, savings, goal and any gaps shown above.</span></label>
    {shownError && <p role="alert">{shownError}</p>}
    {recovery}
    {stale && !mutation.pending
      ? <div className="mia-daily-actions">
        <button type="button" className="mia-daily-save" disabled={busy} onClick={lookAgain}>Look again</button>
        <button type="button" className="secondary-button" disabled={busy} onClick={onOpenCheckpoints}>Open in Checkpoints</button>
        <button type="button" className="mia-daily-dismiss" disabled={busy} onClick={notNow}>Not now</button>
      </div>
      : <div className="mia-daily-actions">
        <button type="button" className="mia-daily-save" disabled={busy || !checked} onClick={() => void approve()}>{busy ? 'Saving…' : `Approve Day ${day}`}</button>
        <button type="button" className="mia-daily-dismiss" disabled={busy} onClick={notNow}>Not now</button>
      </div>}
    <p className="mia-daily-footnote">Nothing is saved until you approve it. To fix an older review, use Checkpoints.</p>
  </section>
}

// Plain facts only. An unknown total is never shown as $0.
function facts(snapshot: CheckpointSnapshot): [string, string][] {
  const { savings, daily } = snapshot
  const rows: [string, string][] = [
    ['Set aside', savings.reported_cents === null ? 'Nothing reported yet' : savingsDollars(savings.reported_cents)],
    ['Your target', savings.target_cents == null ? 'Not chosen yet' : savingsTargetDollars(savings.target_cents)],
  ]
  const checkIns = `${daily.completed_check_in_days} ${daily.completed_check_in_days === 1 ? 'day' : 'days'}${daily.no_spend_days ? `, ${daily.no_spend_days} with no spending` : ''}`
  rows.push(['Check-ins', checkIns])
  if (daily.reported_spend_cents != null && daily.approved_purchase_count > 0) rows.push(['Spending you reported', `${savingsDollars(daily.reported_spend_cents)} in ${daily.approved_purchase_count} ${daily.approved_purchase_count === 1 ? 'purchase' : 'purchases'}`])
  if (daily.unknown_unreported_days > 0) rows.push(['Not checked in', `${daily.unknown_unreported_days} ${daily.unknown_unreported_days === 1 ? 'day' : 'days'} so far, so I don’t know those`])
  return rows
}
