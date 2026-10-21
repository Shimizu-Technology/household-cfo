import { useEffect, useMemo, useRef, useState } from 'react'
import { fetchDailyContext, mutateDaily } from '../api'
import { dailyApproval, dailyContextMatches, dailyResponseMatches, type DailyAction, type DailyContext, type DailyInput, type DailyPurchaseDraft, type DailyScope } from '../lib/dailyChallenge'
import type { BaselineScope } from '../lib/financialBaseline'
import { participantErrorMessage } from '../lib/participantErrorMessage'
import { savingsDollars, savingsInputCents, savingsInputDollars, type DailyReportIntake, type SavingsIntake } from '../lib/savingsChallenge'
import './MiaDailyCheckIn.css'

// "Today", "Yesterday", or "Mon, Oct 20" for a local calendar date.
function plainDay(iso: string, today: string): string {
  if (iso === today) return 'Today'
  const yesterday = new Date(`${today}T00:00:00Z`)
  yesterday.setUTCDate(yesterday.getUTCDate() - 1)
  if (iso === yesterday.toISOString().slice(0, 10)) return 'Yesterday'
  return new Intl.DateTimeFormat('en-US', { weekday: 'short', month: 'short', day: 'numeric', timeZone: 'UTC' }).format(new Date(`${iso}T00:00:00Z`))
}

function CheckIcon() {
  return <svg className="mia-daily-check-icon" viewBox="0 0 20 20" width="18" height="18" aria-hidden="true" focusable="false"><path d="M4 10.5l4 4 8-9" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" /></svg>
}

type PromptProps = { assistantName: string; assistantInitial: string; checkedIn: boolean; disabled: boolean; onNoSpend: () => void; onSpent: () => void }

// Mia's daily question. Client-side only: it is not saved and calls no model.
export function MiaDailyPrompt({ assistantName, assistantInitial, checkedIn, disabled, onNoSpend, onSpent }: PromptProps) {
  return (
    <div className="message-row assistant mia-daily-prompt" role="group" aria-label={`${assistantName} asks about today`}>
      <span className="message-avatar" aria-hidden="true">{assistantInitial}</span>
      <div className="message assistant">
        <strong>{assistantName}</strong>
        <p>{checkedIn ? 'You checked in for today. Spent anything else? Tell me what and where.' : 'How was today? Tell me what you spent and where, or tap No spending today. How you felt is optional.'}</p>
        <div className="mia-daily-chips">
          {!checkedIn && <button type="button" className="mia-daily-chip" disabled={disabled} onClick={onNoSpend}>No spending today</button>}
          <button type="button" className="mia-daily-chip" disabled={disabled} onClick={onSpent}>I spent money</button>
        </div>
      </div>
    </div>
  )
}

type Row = { id: number; amount: string; merchant: string; purchased_on: string; saved: boolean; failed: boolean; draft?: DailyPurchaseDraft; purchaseId?: number; reflected?: boolean }
type CardProps = { report: DailyReportIntake; scope: BaselineScope; cohortId?: number; onSaved: () => void; onEditInToday: (purchase: SavingsIntake | null) => void; onDismiss: () => void }

class StepFailure extends Error {}

// The card under Mia's reply. It lists every item; one tap on Save stages and
// approves each purchase (accepted: true) with stable request keys, so a retry
// replays instead of saving twice. Nothing is recorded before that tap.
export function MiaDailyReportCard({ report, scope, cohortId, onSaved, onEditInToday, onDismiss }: CardProps) {
  const [rows, setRows] = useState<Row[]>(() => report.purchases.map((row, index) => ({ id: index, amount: savingsInputDollars(row.amount_cents), merchant: row.merchant, purchased_on: row.purchased_on, saved: false, failed: false })))
  const [feelingThen, setFeelingThen] = useState(report.feelings?.when_spent ?? '')
  const [feelingNow, setFeelingNow] = useState(report.feelings?.now ?? '')
  const [contexts, setContexts] = useState<Record<string, DailyContext>>({})
  const [phase, setPhase] = useState<'idle' | 'saving' | 'saved'>('idle')
  const [message, setMessage] = useState<string | null>(null)
  const [invalid, setInvalid] = useState<Record<number, string>>({})
  const keys = useRef<Record<string, string>>({})
  const noSpend = report.no_spend
  const dates = useMemo(() => noSpend ? [report.local_on] : [...new Set(rows.map((row) => row.purchased_on))], [noSpend, report.local_on, rows])
  const dateKey = dates.join(',')
  useEffect(() => {
    const controller = new AbortController()
    for (const date of dateKey.split(',')) {
      fetchDailyContext(date, controller.signal).then((context) => {
        if (dailyContextMatches(context, scope, cohortId)) setContexts((current) => ({ ...current, [date]: context }))
      }).catch(() => undefined)
    }
    return () => controller.abort()
  }, [dateKey, scope, cohortId])
  const today = Object.values(contexts)[0]?.calendar.local_today ?? report.local_on
  const firstDay = contexts[report.local_on]?.day
  const noSpendBlocked = noSpend && Boolean(firstDay && firstDay.approved_purchase_count > 0)
  const changesNoSpend = !noSpend && rows.some((row) => !row.saved && contexts[row.purchased_on]?.day?.spending_state === 'no_spend')
  const allToday = dates.every((date) => date === today)
  const pending = rows.filter((row) => !row.saved)
  const busy = phase === 'saving'

  function key(step: string): string {
    keys.current[step] ??= crypto.randomUUID()
    return keys.current[step]
  }

  async function run<T>(action: Exclude<DailyAction, 'reflection_erase'>, input: DailyInput, actor: DailyScope, step: string): Promise<T> {
    const result = await mutateDaily<T>(action, input, key(`${step}:${JSON.stringify(input)}`))
    if (!dailyResponseMatches(result, actor)) throw new StepFailure('Your private workspace changed. Reopen Ask Mia and try again.')
    return result.record
  }

  async function freshContext(date: string): Promise<{ context: DailyContext; actor: DailyScope }> {
    const context = await fetchDailyContext(date)
    if (!dailyContextMatches(context, scope, cohortId) || !context.day) throw new StepFailure('This day is not open for your challenge. Open Today to check it.')
    return { context, actor: { ...scope, enrollment_id: context.enrollment_id, ...(context.cohort_id != null ? { cohort_id: context.cohort_id } : {}) } }
  }

  async function saveNoSpend() {
    const { context, actor } = await freshContext(report.local_on)
    const day = context.day!
    if (day.approved_purchase_count > 0) throw new StepFailure('You already saved a purchase for this day, so it can’t be a no-spend day. Open Today to change it.')
    if (day.spending_state !== 'no_spend') {
      await run('check_in_save', { local_on: day.local_on, spending_state: 'no_spend', accepted: true, expected_version_id: day.check_in_version_id, expected_head_lock_version: day.check_in_lock_version, reason: day.check_in_version_id ? 'Changed in a Mia check-in' : '' }, actor, 'no-spend')
    }
  }

  async function savePurchases(progress: { rows: Row[]; error?: string }): Promise<Row[]> {
    const current = progress.rows
    const update = (id: number, patch: Partial<Row>) => { progress.rows = progress.rows.map((row) => row.id === id ? { ...row, ...patch } : row); setRows(progress.rows) }
    const days: Record<string, { context: DailyContext; actor: DailyScope }> = {}
    for (const date of [...new Set(current.filter((row) => !row.saved).map((row) => row.purchased_on))]) {
      days[date] = await freshContext(date)
      const day = days[date].context.day!
      // A purchase on a day saved as "no spending" changes that day to spending first.
      if (day.spending_state === 'no_spend') {
        await run('check_in_save', { local_on: date, spending_state: 'spending', accepted: true, expected_version_id: day.check_in_version_id, expected_head_lock_version: day.check_in_lock_version, reason: 'Added a purchase in a Mia check-in' }, days[date].actor, `spending:${date}`)
        days[date] = await freshContext(date)
      }
    }
    for (const row of current.filter((item) => !item.saved)) {
      const { actor } = days[row.purchased_on]
      try {
        const draft = row.draft ?? await run<DailyPurchaseDraft>('purchase_stage', { amount_cents: savingsInputCents(row.amount), merchant: row.merchant.trim(), purchased_on: row.purchased_on, link_kind: 'manual_new', expected_version_id: null, expected_head_lock_version: 0 }, actor, `stage:${row.id}`)
        update(row.id, { draft })
        await run('purchase_approve', dailyApproval(draft), actor, `approve:${row.id}`)
        update(row.id, { saved: true, failed: false, purchaseId: draft.savings_daily_purchase_id })
      } catch (failure) {
        update(row.id, { failed: true })
        if (failure instanceof StepFailure) throw failure
        progress.error = participantErrorMessage(failure, 'Try again.')
      }
    }
    // Saving purchases checks the day in, so reminders treat it as reported.
    for (const [date, { context, actor }] of Object.entries(days)) {
      const day = context.day!
      if (!progress.rows.some((row) => row.saved && row.purchased_on === date) || day.spending_state === 'spending') continue
      try {
        await run('check_in_save', { local_on: date, spending_state: 'spending', accepted: true, expected_version_id: day.check_in_version_id, expected_head_lock_version: day.check_in_lock_version, reason: day.check_in_version_id ? 'Purchases saved in a Mia check-in' : '' }, actor, `checkin:${date}`)
      } catch { /* The purchases are saved; the day still reads as spent from them. */ }
    }
    return progress.rows
  }

  async function saveFeelings(current: Row[]): Promise<boolean> {
    const then = feelingThen.trim(), now = feelingNow.trim()
    if (!then && !now) return true
    let ok = true
    let next = current
    for (const row of current.filter((item) => item.saved && item.purchaseId && !item.reflected)) {
      try {
        const { actor } = await freshContext(row.purchased_on)
        await run('reflection_save', { purchase_id: row.purchaseId, expected_version_id: null, expected_head_lock_version: 0, feeling_then: then || null, feeling_now: now || null }, actor, `feelings:${row.purchaseId}`)
        next = next.map((item) => item.id === row.id ? { ...item, reflected: true } : item)
      } catch { ok = false }
    }
    setRows(next)
    return ok
  }

  async function save() {
    if (busy) return
    const problems: Record<number, string> = {}
    for (const row of pending) {
      try { if (savingsInputCents(row.amount) > 2147483647) problems[row.id] = 'Enter a smaller amount.' } catch { problems[row.id] = 'Enter an amount like 8.25.' }
      if (!row.merchant.trim()) problems[row.id] = problems[row.id] ?? 'Add where you spent this.'
      else if (row.merchant.trim().length > 120) problems[row.id] = problems[row.id] ?? 'Use a shorter place name.'
    }
    setInvalid(problems)
    if (Object.keys(problems).length) { setMessage('Check the highlighted item before saving.'); return }
    setPhase('saving'); setMessage(noSpend ? 'Saving…' : `Saving ${pending.length === 1 ? 'your purchase' : `${pending.length} purchases`}…`)
    const progress: { rows: Row[]; error?: string } = { rows }
    try {
      if (noSpend) {
        await saveNoSpend()
        setPhase('saved'); setMessage(null); onSaved(); return
      }
      const result = await savePurchases(progress)
      const failed = result.filter((row) => !row.saved)
      const savedCount = result.length - failed.length
      if (failed.length) {
        const names = failed.map((row) => row.merchant.trim() || savingsDollars(savingsInputCents(row.amount)))
        setMessage(savedCount ? `Saved ${savedCount} of ${result.length}. ${names.join(' and ')} didn’t save — try again.` : `Nothing was saved yet. ${progress.error ?? 'Try again.'}`)
        setPhase('idle')
        if (savedCount) onSaved()
        return
      }
      const feelingsSaved = await saveFeelings(result)
      setPhase('saved')
      setMessage(feelingsSaved ? null : 'Your purchases are saved. How you felt didn’t save — you can add it in Today.')
      onSaved()
    } catch (failure) {
      setPhase('idle')
      const savedCount = progress.rows.filter((row) => row.saved).length
      if (savedCount) onSaved()
      const reason = participantErrorMessage(failure, 'Try again.')
      setMessage(savedCount ? `Saved ${savedCount} of ${progress.rows.length}. ${reason}` : `Nothing was saved yet. ${reason}`)
    }
  }

  function edit(id: number, patch: Partial<Row>) {
    setRows((current) => current.map((row) => row.id === id ? { ...row, ...patch, draft: undefined, failed: false } : row))
    setInvalid((current) => { const copy = { ...current }; delete copy[id]; return copy })
    if (phase === 'saved') setPhase('idle')
  }

  const firstPending = pending[0]
  const editIntake: SavingsIntake | null = firstPending ? (() => { try { return { kind: 'purchase', amount_cents: savingsInputCents(firstPending.amount), effective_on: firstPending.purchased_on, merchant: firstPending.merchant.trim(), approval_state: 'unreviewed_input', counted: false } } catch { return null } })() : null
  const feelingsOpen = Boolean(report.feelings?.when_spent || report.feelings?.now)
  const saved = phase === 'saved'
  const dayWord = plainDay(report.local_on, today) === 'Today' ? 'today' : `on ${plainDay(report.local_on, today)}`
  const title = saved ? (allToday ? 'Saved to today' : 'Saved') : noSpend ? `No spending ${dayWord}` : rows.length === 1 ? 'Check this, then save' : 'Check these, then save'

  return (
    <section className={`mia-daily-card${saved ? ' is-saved' : ''}`} aria-label="Your check-in" aria-busy={busy}>
      <h3>{saved && <CheckIcon />}{title}</h3>
      {noSpend ? <p className="mia-daily-nospend">{saved ? `No spending ${dayWord}.` : 'Saving records a no-spend day, which is different from a day you skip.'}</p> : (
        <ul className="mia-daily-rows">
          {rows.map((row, index) => {
            const label = row.merchant.trim() || `purchase ${index + 1}`
            return (
              <li key={row.id} className={`mia-daily-row${row.saved ? ' is-saved' : ''}${row.failed || invalid[row.id] ? ' has-problem' : ''}`}>
                {row.saved ? <p className="mia-daily-saved-row"><CheckIcon /><span><strong>{savingsDollars(savingsInputCents(row.amount))}</strong> · {row.merchant} · {plainDay(row.purchased_on, today)}</span></p> : <>
                  <label className="mia-daily-amount"><span aria-hidden="true">$</span><input aria-label={`Amount for ${label}`} inputMode="decimal" autoComplete="off" value={row.amount} disabled={busy} aria-invalid={Boolean(invalid[row.id]) || undefined} onChange={(event) => edit(row.id, { amount: event.target.value })} /></label>
                  <label className="mia-daily-place"><input aria-label={`Place for ${label}`} maxLength={120} autoComplete="off" placeholder="Where?" value={row.merchant} disabled={busy} aria-invalid={Boolean(invalid[row.id]) || undefined} onChange={(event) => edit(row.id, { merchant: event.target.value })} /></label>
                  <span className="mia-daily-day">{plainDay(row.purchased_on, today)}</span>
                  <button type="button" className="mia-daily-remove" disabled={busy} aria-label={`Remove ${label}`} onClick={() => { setRows((current) => current.filter((item) => item.id !== row.id)); setInvalid((current) => { const copy = { ...current }; delete copy[row.id]; return copy }) }}><span aria-hidden="true">×</span></button>
                  {(invalid[row.id] || row.failed) && <p className="mia-daily-row-note">{invalid[row.id] ?? 'This one didn’t save. Try again.'}</p>}
                </>}
              </li>
            )
          })}
          {!rows.length && <li className="mia-daily-empty">Nothing left to save.</li>}
        </ul>
      )}
      {!noSpend && rows.length > 0 && !saved && (feelingsOpen
        ? <fieldset className="mia-daily-feelings" disabled={busy}><legend>How you felt (optional)</legend><FeelingFields then={feelingThen} now={feelingNow} onThen={setFeelingThen} onNow={setFeelingNow} /></fieldset>
        : <details className="mia-daily-feelings"><summary>Add how you felt (optional)</summary><fieldset disabled={busy}><legend className="sr-only">How you felt (optional)</legend><FeelingFields then={feelingThen} now={feelingNow} onThen={setFeelingThen} onNow={setFeelingNow} /></fieldset></details>)}
      {noSpendBlocked && !saved && <p className="mia-daily-hint">You already saved a purchase for this day, so it can’t be a no-spend day.</p>}
      {changesNoSpend && !saved && <p className="mia-daily-hint">You saved this day as no spending. Saving a purchase changes it to a spending day.</p>}
      {message && <p className="mia-daily-status" role="status">{message}</p>}
      {!saved && <p className="mia-daily-footnote">Nothing is saved until you tap {allToday ? 'Save to today' : 'Save'}.{noSpend ? '' : ' Feelings stay private.'}</p>}
      {!saved ? (
        <div className="mia-daily-actions">
          <button type="button" className="mia-daily-save" disabled={busy || noSpendBlocked || (!noSpend && pending.length === 0)} onClick={() => void save()}>{busy ? 'Saving…' : allToday ? 'Save to today' : 'Save'}</button>
          <button type="button" className="secondary-button" disabled={busy} onClick={() => onEditInToday(editIntake)}>Edit in Today</button>
          <button type="button" className="mia-daily-dismiss" disabled={busy} onClick={onDismiss}>Not right</button>
        </div>
      ) : <div className="mia-daily-actions"><button type="button" className="mia-daily-dismiss" onClick={onDismiss}>Done</button></div>}
    </section>
  )
}

function FeelingFields({ then, now, onThen, onNow }: { then: string; now: string; onThen: (value: string) => void; onNow: (value: string) => void }) {
  return <>
    <label>How did you feel when you spent?<input maxLength={140} value={then} onChange={(event) => onThen(event.target.value)} /></label>
    <label>How do you feel now?<input maxLength={140} value={now} onChange={(event) => onNow(event.target.value)} /></label>
  </>
}
