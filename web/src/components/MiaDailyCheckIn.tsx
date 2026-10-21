import { useEffect, useMemo, useRef, useState } from 'react'
import { fetchDailyContext, fetchDailyRequestStatus } from '../api'
import { dailyApproval, dailyContextMatches, dailyResponseMatches, type DailyAction, type DailyContext, type DailyInput, type DailyPurchaseDraft, type DailyScope } from '../lib/dailyChallenge'
import { readDailyCard, useDailyCard, writeDailyCard, type DailyCardRow, type DailyCardState } from '../lib/dailyCheckIn'
import { clearDailyRecovery, readDailyRecovery } from '../lib/dailyRecovery'
import type { BaselineScope } from '../lib/financialBaseline'
import { savingsDollars, savingsInputCents, savingsInputDollars, type DailyReportIntake, type SavingsIntake } from '../lib/savingsChallenge'
import { useDailyMutation } from '../lib/useDailyMutation'
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

type PromptProps = { assistantName: string; assistantInitial: string; disabled: boolean; onNoSpend: () => void; onSpent: () => void }

// Mia's daily question, shown only until today is checked in. Client-side
// only: it is not saved and calls no model.
export function MiaDailyPrompt({ assistantName, assistantInitial, disabled, onNoSpend, onSpent }: PromptProps) {
  return (
    <div className="message-row assistant mia-daily-prompt" role="group" aria-label={`${assistantName} asks about today`}>
      <span className="message-avatar" aria-hidden="true">{assistantInitial}</span>
      <div className="message assistant">
        <strong>{assistantName}</strong>
        <p>How was today? Tell me what you spent and where, or tap No spending today. How you felt is optional.</p>
        <div className="mia-daily-chips">
          <button type="button" className="mia-daily-chip" disabled={disabled} onClick={onNoSpend}>No spending today</button>
          <button type="button" className="mia-daily-chip" disabled={disabled} onClick={onSpent}>I spent money</button>
        </div>
      </div>
    </div>
  )
}

type CardProps = { nonce: string; report: DailyReportIntake; scope: BaselineScope; cohortId?: number; onSaved: () => void; onEditInToday: (purchase: SavingsIntake, remaining: number) => void; onDismiss: () => void }
type Perform = (action: Exclude<DailyAction, 'reflection_erase'>, input: DailyInput, reflectionId: undefined, key: string) => Promise<unknown | null>

const locked = (row: DailyCardRow) => row.draft !== undefined || row.status === 'saving' || row.status === 'unknown'
const open = (row: DailyCardRow) => row.status !== 'saved' && row.status !== 'moved'
const label = (row: DailyCardRow, index: number) => row.merchant.trim() || `purchase ${index + 1}`
const sentence = (text: string) => text.charAt(0).toUpperCase() + text.slice(1)
// The card is done once the whole save finished: purchases, the day's check-in
// and feelings (no-spend: once that is saved). Saved rows alone are not enough,
// so a save interrupted after its purchases still finishes the day.
const finished = (state: DailyCardState, noSpend: boolean) => noSpend ? state.noSpendSaved : state.phase === 'saved'

class Stop extends Error {}

// The card under Mia's reply. It lists every item; one tap on Save stages and
// approves each purchase (accepted: true). Progress, staged drafts and request
// keys live outside the card, and writes go through the shared daily request
// guard, so a retry replays the same request and an unconfirmed one must be
// checked before anything new is sent. Nothing is recorded before that tap.
export function MiaDailyReportCard({ nonce, report, scope, cohortId, onSaved, onEditInToday, onDismiss }: CardProps) {
  const noSpend = report.no_spend
  const state = useDailyCard(nonce, () => ({
    rows: report.purchases.map((row, index) => ({ id: index, amount: savingsInputDollars(row.amount_cents), merchant: row.merchant, purchased_on: row.purchased_on, status: 'pending' })),
    feelingThen: report.feelings?.when_spent ?? '', feelingNow: report.feelings?.now ?? '', keys: {}, phase: 'idle', message: null, switchedToSpending: [], checkedIn: [], noSpendSaved: false,
  }))
  const update = (change: (current: DailyCardState) => DailyCardState) => writeDailyCard(nonce, change)
  const patchRow = (id: number, patch: Partial<DailyCardRow>) => update((current) => ({ ...current, rows: current.rows.map((row) => row.id === id ? { ...row, ...patch } : row) }))
  const [contexts, setContexts] = useState<Record<string, DailyContext>>({})
  const [invalid, setInvalid] = useState<Record<number, string>>({})
  const headingRef = useRef<HTMLHeadingElement>(null)
  const cardRef = useRef<HTMLElement>(null)
  const dates = useMemo(() => noSpend ? [report.local_on] : [...new Set(state.rows.map((row) => row.purchased_on))], [noSpend, report.local_on, state.rows])
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
  const anyContext = Object.values(contexts)[0]
  const actor = useMemo<DailyScope | undefined>(() => anyContext ? { ...scope, enrollment_id: anyContext.enrollment_id, ...(anyContext.cohort_id != null ? { cohort_id: anyContext.cohort_id } : {}) } : undefined, [anyContext, scope])
  const mutation = useDailyMutation(actor, () => undefined)
  const perform = mutation.mutate as unknown as Perform
  const today = anyContext?.calendar.local_today ?? report.local_on
  const firstDay = contexts[report.local_on]?.day
  const saved = finished(state, noSpend)
  const busy = state.phase === 'saving'
  const noSpendBlocked = noSpend && !saved && Boolean(firstDay && firstDay.approved_purchase_count > 0)
  const openRows = state.rows.filter(open)
  // Purchases saved, but the day's check-in or feelings were left (an interrupted save).
  const finishing = !noSpend && !saved && openRows.length === 0 && state.rows.some((row) => row.status === 'saved')
  const changesNoSpend = !noSpend && openRows.some((row) => contexts[row.purchased_on]?.day?.spending_state === 'no_spend')
  const allToday = dates.every((date) => date === today)
  const ownKeys = new Set(Object.values(state.keys))
  const foreignPending = mutation.pending && !ownKeys.has(mutation.pending.key) ? mutation.pending : null
  const unconfirmed = state.rows.filter((row) => row.status === 'unknown')

  // One stable request key per exact request, kept with the card.
  function keyFor(step: string, input: DailyInput): string {
    const id = `${step}:${JSON.stringify(input)}`
    const existing = readDailyCard(nonce)?.keys[id]
    if (existing) return existing
    const key = crypto.randomUUID()
    update((current) => ({ ...current, keys: { ...current.keys, [id]: key } }))
    return key
  }

  // Sends through the shared daily guard. A missing result is either a definite
  // failure (the guard released it) or unconfirmed (the guard still holds it).
  async function send<T>(action: Exclude<DailyAction, 'reflection_erase'>, input: DailyInput, step: string, rowId?: number): Promise<{ record: T } | { unknown: true } | { failed: true }> {
    const key = keyFor(step, input)
    // Recorded before sending: if the page closes mid-request, the restored card
    // checks this request's result before anything new is sent.
    update((current) => ({ ...current, unconfirmed: { action, input, key, rowId } }))
    const record = await perform(action, input, undefined, key)
    if (record) { update((current) => current.unconfirmed?.key === key ? { ...current, unconfirmed: undefined } : current); return { record: record as T } }
    if (actor && readDailyRecovery(actor)?.key === key) return { unknown: true }
    update((current) => current.unconfirmed?.key === key ? { ...current, unconfirmed: undefined } : current)
    return { failed: true }
  }

  // An unconfirmed request is sent again first, with its own key: the server
  // replays it if it already saved, so nothing is saved twice.
  async function settleUnconfirmed() {
    const pending = readDailyCard(nonce)?.unconfirmed
    if (!pending || !actor) return
    const record = await perform(pending.action, pending.input, undefined, pending.key)
    if (!record && readDailyRecovery(actor)?.key === pending.key) throw new Stop('unknown')
    update((current) => ({ ...current, unconfirmed: undefined }))
    if (record) applyConfirmed(pending, record)
  }

  // Apply what a confirmed request did, so it is never sent a third time.
  function applyConfirmed(pending: NonNullable<DailyCardState['unconfirmed']>, record: unknown) {
    const row = pending.rowId === undefined ? undefined : readDailyCard(nonce)?.rows.find((item) => item.id === pending.rowId)
    if (pending.action === 'purchase_stage' && row) patchRow(row.id, { draft: record as DailyPurchaseDraft, status: 'pending' })
    else if (pending.action === 'purchase_approve' && row?.draft) patchRow(row.id, { status: 'saved', purchaseId: row.draft.savings_daily_purchase_id })
    else if (pending.action === 'check_in_save') {
      const date = pending.input.local_on as string
      update((current) => pending.input.spending_state === 'no_spend'
        ? { ...current, noSpendSaved: true, phase: 'saved' }
        : { ...current, checkedIn: [...new Set([...current.checkedIn, date])], switchedToSpending: [...new Set([...current.switchedToSpending, date])] })
    } else if (pending.action === 'reflection_save') {
      update((current) => ({ ...current, rows: current.rows.map((item) => item.purchaseId === pending.input.purchase_id ? { ...item, reflected: true } : item) }))
    }
  }

  // Before offering a new write after remount/reload, look up the interrupted
  // request. If it is still running or the lookup fails, keep writes blocked
  // and offer another lookup; an unknown request replays its original body/key.
  const [reconciling, setReconciling] = useState(() => Boolean(readDailyCard(nonce)?.unconfirmed))
  const [checking, setChecking] = useState(false)
  const [statusAttempt, setStatusAttempt] = useState(0)
  useEffect(() => {
    const pending = readDailyCard(nonce)?.unconfirmed
    if (!actor || !pending || readDailyCard(nonce)?.phase === 'saving') { if (!pending) queueMicrotask(() => setReconciling(false)); return }
    let live = true
    queueMicrotask(() => { if (live) { setReconciling(true); setChecking(true) } })
    fetchDailyRequestStatus(pending.action, pending.key).then((status) => {
      if (!live) return
      if (!dailyResponseMatches(status, actor)) throw new Error('Private workspace changed')
      if (status.state === 'in_flight') { update((current) => ({ ...current, message: 'Still checking your last save. Try again in a moment.' })); return }
      if (status.state === 'committed') {
        applyConfirmed(pending, status.record)
        clearDailyRecovery(pending.key)
        update((current) => ({ ...current, unconfirmed: undefined, message: null }))
        onSaved()
      }
      setReconciling(false)
    }).catch(() => { if (live) update((current) => ({ ...current, message: 'We couldn’t check your last save. Check again before saving anything else.' })) })
      .finally(() => { if (live) setChecking(false) })
    return () => { live = false }
    // The restored request is stable; writing ordinary progress must not restart this lookup.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [actor, nonce, statusAttempt])

  async function freshDay(date: string) {
    const context = await fetchDailyContext(date)
    if (!dailyContextMatches(context, scope, cohortId) || !context.day) throw new Stop('This day isn’t open for your challenge. Open Today to check it.')
    setContexts((current) => ({ ...current, [date]: context }))
    return context.day
  }

  async function saveNoSpend() {
    const day = await freshDay(report.local_on)
    if (day.approved_purchase_count > 0) throw new Stop('You already saved a purchase for this day, so it can’t be a no-spend day. Open Today to change it.')
    if (day.spending_state !== 'no_spend') {
      const result = await send('check_in_save', { local_on: day.local_on, spending_state: 'no_spend', accepted: true, expected_version_id: day.check_in_version_id, expected_head_lock_version: day.check_in_lock_version, reason: day.check_in_version_id ? 'Changed in a Mia check-in' : '' }, 'no-spend')
      if ('unknown' in result) throw new Stop('We couldn’t confirm this saved. Tap Save to check — it won’t save twice.')
      if ('failed' in result) throw new Stop('Nothing was saved yet. Try again.')
    }
    update((current) => ({ ...current, noSpendSaved: true }))
  }

  async function saveRow(row: DailyCardRow, day: Awaited<ReturnType<typeof freshDay>>) {
    patchRow(row.id, { status: 'saving', error: undefined })
    let draft = row.draft
    if (!draft) {
      const staged = await send<DailyPurchaseDraft>('purchase_stage', { amount_cents: savingsInputCents(row.amount), merchant: row.merchant.trim(), purchased_on: row.purchased_on, link_kind: 'manual_new', expected_version_id: null, expected_head_lock_version: 0 }, `stage:${row.id}`, row.id)
      if ('unknown' in staged) { patchRow(row.id, { status: 'unknown' }); throw new Stop('unknown') }
      if ('failed' in staged) { patchRow(row.id, { status: 'failed', error: 'This one didn’t save. Try again.' }); return }
      draft = staged.record
      patchRow(row.id, { draft })
    }
    // The server accepts a purchase on a no-spend day only after that day is
    // changed, so it is changed right before this purchase is approved.
    const current = readDailyCard(nonce)!
    if (day.spending_state === 'no_spend' && !current.switchedToSpending.includes(row.purchased_on)) {
      const switched = await send('check_in_save', { local_on: row.purchased_on, spending_state: 'spending', accepted: true, expected_version_id: day.check_in_version_id, expected_head_lock_version: day.check_in_lock_version, reason: 'Added a purchase in a Mia check-in' }, `spending:${row.purchased_on}`, row.id)
      if ('unknown' in switched) { patchRow(row.id, { status: 'unknown' }); throw new Stop('unknown') }
      if ('failed' in switched) { patchRow(row.id, { status: 'failed', error: 'This one didn’t save. Try again.' }); return }
      update((value) => ({ ...value, switchedToSpending: [...value.switchedToSpending, row.purchased_on] }))
    }
    const approved = await send('purchase_approve', dailyApproval(draft), `approve:${row.id}`, row.id)
    if ('unknown' in approved) { patchRow(row.id, { status: 'unknown' }); throw new Stop('unknown') }
    // A definite refusal (stale versions) did not save; the next Save stages afresh.
    if ('failed' in approved) {
      // Drop the stage key with the draft, or the next Save would replay that stale draft.
      update((current) => ({ ...current, keys: Object.fromEntries(Object.entries(current.keys).filter(([id]) => !id.startsWith(`stage:${row.id}:`))) }))
      patchRow(row.id, { status: 'failed', draft: undefined, error: 'This one didn’t save. Try again.' })
      return
    }
    patchRow(row.id, { status: 'saved', purchaseId: draft.savings_daily_purchase_id })
  }

  async function savePurchases() {
    const days: Record<string, Awaited<ReturnType<typeof freshDay>>> = {}
    // Unconfirmed rows first, so their requests are settled before anything new.
    const ordered = readDailyCard(nonce)!.rows.filter(open).sort((left, right) => Number(right.status === 'unknown') - Number(left.status === 'unknown'))
    for (const row of ordered) {
      const latest = readDailyCard(nonce)!.rows.find((item) => item.id === row.id)!
      days[row.purchased_on] ??= await freshDay(row.purchased_on)
      if (latest.status !== 'saved') await saveRow(latest, days[row.purchased_on])
    }
    // Saving purchases checks the day in, so reminders treat it as reported,
    // including days whose purchases were saved before an interruption.
    for (const row of readDailyCard(nonce)!.rows.filter((item) => item.status === 'saved')) days[row.purchased_on] ??= await freshDay(row.purchased_on)
    for (const [date, day] of Object.entries(days)) {
      const card = readDailyCard(nonce)!
      if (!card.rows.some((row) => row.status === 'saved' && row.purchased_on === date) || card.checkedIn.includes(date) || card.switchedToSpending.includes(date) || day.spending_state === 'spending') continue
      const result = await send('check_in_save', { local_on: date, spending_state: 'spending', accepted: true, expected_version_id: day.check_in_version_id, expected_head_lock_version: day.check_in_lock_version, reason: day.check_in_version_id ? 'Purchases saved in a Mia check-in' : '' }, `checkin:${date}`)
      if ('record' in result) update((value) => ({ ...value, checkedIn: [...value.checkedIn, date] }))
      else if ('unknown' in result) throw new Stop('unknown')
      else throw new Stop('Your purchases are saved. The check-in didn’t save — tap Save to finish it.')
    }
    // Optional feelings, kept separately with each purchase saved here.
    const card = readDailyCard(nonce)!
    const then = card.feelingThen.trim(), now = card.feelingNow.trim()
    let feelingsSaved = true
    if (then || now) {
      for (const row of card.rows.filter((item) => item.status === 'saved' && item.purchaseId && !item.reflected)) {
        const result = await send('reflection_save', { purchase_id: row.purchaseId, expected_version_id: null, expected_head_lock_version: 0, feeling_then: then || null, feeling_now: now || null }, `feelings:${row.purchaseId}`)
        if ('record' in result) patchRow(row.id, { reflected: true })
        else if ('unknown' in result) throw new Stop('unknown')
        else feelingsSaved = false
      }
    }
    return feelingsSaved
  }

  function summary(card: DailyCardState, feelingsSaved: boolean): string | null {
    const rows = card.rows.filter((row) => row.status !== 'moved')
    const savedCount = rows.filter((row) => row.status === 'saved').length
    const failed = rows.filter((row) => row.status !== 'saved')
    if (!failed.length) return feelingsSaved ? null : 'Your purchases are saved. How you felt didn’t save — tap Save to try again, or clear the feelings.'
    const names = failed.map((row, index) => label(row, index))
    const stillSpending = card.switchedToSpending.filter((date) => !rows.some((row) => row.status === 'saved' && row.purchased_on === date))
    const dayNote = stillSpending.length ? ' This day now shows as a spending day.' : ''
    return savedCount ? `Saved ${savedCount} of ${rows.length}. ${sentence(names.join(' and '))} didn’t save — try again.${dayNote}` : `Nothing was saved yet. ${failed.find((row) => row.error)?.error ?? 'Try again.'}${dayNote}`
  }

  async function save() {
    if (busy || reconciling || foreignPending) return
    const problems: Record<number, string> = {}
    for (const row of state.rows.filter((item) => open(item) && !locked(item))) {
      try { if (savingsInputCents(row.amount) > 2147483647) problems[row.id] = 'Enter a smaller amount.' } catch { problems[row.id] = 'Enter an amount like 8.25.' }
      if (!row.merchant.trim()) problems[row.id] = problems[row.id] ?? 'Add where you spent this.'
      else if (row.merchant.trim().length > 120) problems[row.id] = problems[row.id] ?? 'Use a shorter place name.'
    }
    setInvalid(problems)
    if (Object.keys(problems).length) { update((current) => ({ ...current, message: 'Check the highlighted item before saving.' })); return }
    update((current) => ({ ...current, phase: 'saving', message: noSpend ? 'Saving…' : `Saving ${openRows.length === 1 ? 'your purchase' : `${openRows.length} purchases`}…` }))
    try {
      await settleUnconfirmed()
      let feelingsSaved = true
      if (noSpend) await saveNoSpend()
      else feelingsSaved = await savePurchases()
      const card = readDailyCard(nonce)!
      const complete = noSpend ? card.noSpendSaved : feelingsSaved && !card.unconfirmed && !card.rows.some(open) && card.rows.some((row) => row.status === 'saved')
      update((current) => ({ ...current, phase: complete ? 'saved' : 'idle', message: noSpend ? null : summary(card, feelingsSaved) }))
    } catch (failure) {
      const text = failure instanceof Stop && failure.message !== 'unknown' ? failure.message : 'We couldn’t confirm the last save. Tap Save to check — it won’t save twice.'
      const card = readDailyCard(nonce)!
      const partial = noSpend ? null : summary(card, true)
      update((current) => ({ ...current, phase: 'idle', message: failure instanceof Stop ? text : partial && !partial.startsWith('Nothing') ? partial : text }))
    }
    const after = readDailyCard(nonce)
    if (after && (after.noSpendSaved || after.rows.some((row) => row.status === 'saved'))) onSaved()
    requestAnimationFrame(() => headingRef.current?.focus())
  }

  function edit(id: number, patch: Partial<DailyCardRow>) {
    patchRow(id, { ...patch, status: 'pending', error: undefined })
    setInvalid((current) => { const copy = { ...current }; delete copy[id]; return copy })
  }

  function remove(id: number) {
    const rows = readDailyCard(nonce)!.rows
    const index = rows.findIndex((row) => row.id === id)
    update((current) => ({ ...current, rows: current.rows.filter((row) => row.id !== id) }))
    setInvalid((current) => { const copy = { ...current }; delete copy[id]; return copy })
    const next = rows.slice(index + 1).find((row) => open(row) && !locked(row)) ?? rows.slice(0, index).reverse().find((row) => open(row) && !locked(row))
    requestAnimationFrame(() => {
      const target = next ? cardRef.current?.querySelector<HTMLInputElement>(`[data-row-amount="${next.id}"]`) : cardRef.current?.querySelector<HTMLButtonElement>('.mia-daily-save')
      target?.focus()
    })
  }

  // "Edit in Today" hands one unlocked purchase to the Today form and keeps the rest here.
  const movable = state.rows.find((row) => open(row) && !locked(row))
  function moveToToday() {
    if (!movable) return
    let intake: SavingsIntake
    try { intake = { kind: 'purchase', amount_cents: savingsInputCents(movable.amount), effective_on: movable.purchased_on, merchant: movable.merchant.trim(), approval_state: 'unreviewed_input', counted: false } }
    catch { setInvalid((current) => ({ ...current, [movable.id]: 'Enter an amount like 8.25.' })); return }
    const remaining = state.rows.filter((row) => open(row) && row.id !== movable.id)
    const names = remaining.map((row) => label(row, state.rows.indexOf(row)))
    update((current) => ({ ...current, rows: current.rows.map((row) => row.id === movable.id ? { ...row, status: 'moved' } : row),
      message: remaining.length ? `Moved ${label(movable, state.rows.indexOf(movable))} to Today. ${sentence(names.join(' and '))} ${remaining.length === 1 ? 'is' : 'are'} still here to save.` : null }))
    onEditInToday(intake, remaining.length)
  }

  const dayWord = plainDay(report.local_on, today) === 'Today' ? 'today' : `on ${plainDay(report.local_on, today)}`
  const visibleRows = state.rows.filter((row) => row.status !== 'moved')
  const title = saved ? (allToday ? 'Saved to today' : 'Saved') : noSpend ? `No spending ${dayWord}` : finishing ? 'Almost done' : visibleRows.filter(open).length === 1 ? 'Check this, then save' : 'Check these, then save'
  const feelingsOpen = Boolean(report.feelings?.when_spent || report.feelings?.now)
  const setFeeling = (field: 'feelingThen' | 'feelingNow', value: string) => update((current) => ({ ...current, [field]: value }))
  const statusText = finishing && !busy && !reconciling && !state.message ? `Your purchases are saved. Tap ${allToday ? 'Save to today' : 'Save'} to finish this check-in.` : foreignPending ? 'An earlier daily save needs checking first. Nothing new is sent until it is.' : unconfirmed.length && !busy ? `We couldn’t confirm ${unconfirmed.map((row) => label(row, state.rows.indexOf(row))).join(' and ')} saved. Tap Save to check — it won’t save twice.` : state.message ?? ''

  return (
    <section ref={cardRef} className={`mia-daily-card${saved ? ' is-saved' : ''}`} aria-label="Your check-in" aria-busy={busy}>
      <h3 ref={headingRef} tabIndex={-1}>{saved && <CheckIcon />}{title}</h3>
      {noSpend ? <p className="mia-daily-nospend">{saved ? `No spending ${dayWord}.` : 'Saving records a no-spend day, which is different from a day you skip.'}</p> : (
        <ul className="mia-daily-rows">
          {visibleRows.map((row) => {
            const index = state.rows.indexOf(row)
            const name = label(row, index)
            const noteId = `${nonce}-row-${row.id}-note`
            const note = invalid[row.id] ?? (row.status === 'failed' ? row.error ?? 'This one didn’t save. Try again.' : row.status === 'unknown' ? 'Checking… Tap Save to confirm.' : null)
            const fieldsLocked = busy || locked(row)
            return (
              <li key={row.id} className={`mia-daily-row${row.status === 'saved' ? ' is-saved' : ''}${note && row.status !== 'unknown' ? ' has-problem' : ''}`}>
                {row.status === 'saved' ? <p className="mia-daily-saved-row"><CheckIcon /><span><strong>{savingsDollars(savingsInputCents(row.amount))}</strong> · {row.merchant} · {plainDay(row.purchased_on, today)}</span></p> : <>
                  <label className="mia-daily-amount"><span aria-hidden="true">$</span><input data-row-amount={row.id} aria-label={`Amount for ${name}`} aria-describedby={note ? noteId : undefined} inputMode="decimal" autoComplete="off" value={row.amount} disabled={fieldsLocked} aria-invalid={Boolean(invalid[row.id]) || undefined} onChange={(event) => edit(row.id, { amount: event.target.value })} /></label>
                  <label className="mia-daily-place"><input aria-label={`Place for ${name}`} aria-describedby={note ? noteId : undefined} maxLength={120} autoComplete="off" placeholder="Where?" value={row.merchant} disabled={fieldsLocked} aria-invalid={Boolean(invalid[row.id]) || undefined} onChange={(event) => edit(row.id, { merchant: event.target.value })} /></label>
                  <span className="mia-daily-day">{plainDay(row.purchased_on, today)}</span>
                  <button type="button" className="mia-daily-remove" disabled={fieldsLocked} aria-label={`Remove ${name}`} onClick={() => remove(row.id)}><span aria-hidden="true">×</span></button>
                  {note && <p id={noteId} className="mia-daily-row-note">{note}</p>}
                </>}
              </li>
            )
          })}
          {!visibleRows.length && <li className="mia-daily-empty">Nothing left to save here.</li>}
        </ul>
      )}
      {!noSpend && !saved && (feelingsOpen
        ? <fieldset className="mia-daily-feelings" disabled={busy || Boolean(state.unconfirmed)}><legend>How you felt (optional)</legend><FeelingFields then={state.feelingThen} now={state.feelingNow} onThen={(value) => setFeeling('feelingThen', value)} onNow={(value) => setFeeling('feelingNow', value)} /></fieldset>
        : <details className="mia-daily-feelings"><summary>Add how you felt (optional)</summary><fieldset disabled={busy || Boolean(state.unconfirmed)}><legend className="sr-only">How you felt (optional)</legend><FeelingFields then={state.feelingThen} now={state.feelingNow} onThen={(value) => setFeeling('feelingThen', value)} onNow={(value) => setFeeling('feelingNow', value)} /></fieldset></details>)}
      {noSpendBlocked && <p className="mia-daily-hint">You already saved a purchase for this day, so it can’t be a no-spend day.</p>}
      {changesNoSpend && !saved && <p className="mia-daily-hint">You saved this day as no spending. Saving a purchase changes it to a spending day.</p>}
      <p className="mia-daily-status" role="status">{statusText}</p>
      {reconciling && <button type="button" className="secondary-button" disabled={checking} onClick={() => setStatusAttempt((value) => value + 1)}>{checking ? 'Checking last save…' : 'Check last save'}</button>}
      {foreignPending && mutation.checkStatus && <button type="button" className="secondary-button" disabled={foreignPending.working} onClick={() => void mutation.checkStatus?.()}>Check the earlier save first</button>}
      {!saved && <p className="mia-daily-footnote">Nothing is saved until you tap {allToday ? 'Save to today' : 'Save'}.{noSpend ? '' : ' Feelings stay private.'}</p>}
      {!saved ? (
        <div className="mia-daily-actions">
          <button type="button" className="mia-daily-save" disabled={busy || reconciling || Boolean(foreignPending) || noSpendBlocked || !actor || (!noSpend && openRows.length === 0 && !finishing)} onClick={() => void save()}>{busy ? 'Saving…' : allToday ? 'Save to today' : 'Save'}</button>
          {!noSpend && <button type="button" className="secondary-button" disabled={busy || !movable} onClick={moveToToday}>Edit in Today</button>}
          <button type="button" className="mia-daily-dismiss" disabled={busy || Boolean(state.unconfirmed)} onClick={onDismiss}>Not right</button>
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
