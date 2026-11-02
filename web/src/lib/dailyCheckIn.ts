import { useEffect, useState, useSyncExternalStore } from 'react'
import { ApiRequestError, fetchDailyContext, updateChallengeChatCard } from '../api'
import type { BaselineScope } from './financialBaseline'
import { dailyContextMatches, type DailyAction, type DailyContext, type DailyDay, type DailyInput, type DailyPurchaseDraft, type DailyScope } from './dailyChallenge'
import type { ChallengeChatCard } from './challengeChatCards'
import type { DailyMutate } from './useDailyMutation'
import { readDailyRecovery } from './dailyRecovery'
import { checkedDailyReport } from './savingsChallenge'
import type { DailyReportIntake } from './savingsChallenge'

// Mia daily report cards keep their progress here, outside the card component,
// so leaving Ask Mia, reloading or closing the tab restores staged drafts,
// request keys and saved rows instead of offering to save the same purchases
// again. Like the chat history this tab already keeps, the card is mirrored to
// sessionStorage for this tab only, scoped to the signed-in participant,
// household and program, and cleared on Done/dismiss, program change and sign-out.
export type DailyCardRow = {
  id: number; amount: string; merchant: string; purchased_on: string
  // pending: editable; saving: request in progress; unknown: result not confirmed (locked);
  // failed: a definite failure; saved: approved; moved: handed to the Today form.
  status: 'pending' | 'saving' | 'unknown' | 'failed' | 'saved' | 'moved'
  draft?: DailyPurchaseDraft; purchaseId?: number; reflected?: boolean; error?: string
}
export type DailyCardState = {
  rows: DailyCardRow[]; feelingThen: string; feelingNow: string
  keys: Record<string, string>; phase: 'idle' | 'saving' | 'saved'
  message: string | null; switchedToSpending: string[]; checkedIn: string[]; noSpendSaved: boolean
  // The last request whose result is not confirmed; it is replayed before anything new.
  unconfirmed?: { action: Exclude<DailyAction, 'reflection_erase'>; input: DailyInput; key: string; rowId?: number }
}
export type DailyCardEntry = { scope: string; report: DailyReportIntake; nonce: string }
const STORAGE_PREFIX = 'household-cfo:mia-daily-cards:v1:'
const cards = new Map<string, DailyCardState>()
const entries = new Map<string, DailyCardEntry>()
const cardListeners = new Set<() => void>()
const subscribeCards = (listener: () => void) => { cardListeners.add(listener); return () => { cardListeners.delete(listener) } }
const syncTimers = new Map<string, ReturnType<typeof setTimeout>>()
const serverCards = new Map<string, { card: ChallengeChatCard; queue: Promise<void> }>()

export function registerServerDailyCard(card: ChallengeChatCard, scope: string): DailyCardEntry | null {
  const report = checkedDailyReport(card.input)
  if (card.kind !== 'daily_report' || card.status !== 'pending' || !report) return null
  const nonce = `server-card-${card.id}`
  const tracked = serverCards.get(nonce)
  if (tracked) {
    if (card.lock_version > tracked.card.lock_version) tracked.card = card
  } else {
    serverCards.set(nonce, { card, queue: Promise.resolve() })
    const state = card.state as DailyCardState
    if (Array.isArray(state.rows)) cards.set(nonce, { ...state, phase: state.phase === 'saving' ? 'idle' : state.phase,
      rows: state.rows.map((row) => row.status === 'saving' ? { ...row, status: state.unconfirmed?.rowId === row.id ? 'unknown' : 'pending' } : row) })
  }
  const entry = { scope, report, nonce }
  registerDailyCard(entry)
  return entry
}

// Serialize writes per card. A financial request waits for its exact key and
// unconfirmed input to reach the server, so a fresh tab can safely reconcile it.
function scheduleDailyCardSync(nonce: string) {
  if (!serverCards.has(nonce)) return
  clearTimeout(syncTimers.get(nonce))
  syncTimers.set(nonce, setTimeout(() => { syncTimers.delete(nonce); void syncDailyCard(nonce).catch(() => undefined) }, 300))
}

export class DailyCardSyncUnavailable extends Error {}

export async function syncDailyCard(nonce: string): Promise<void> {
  clearTimeout(syncTimers.get(nonce)); syncTimers.delete(nonce)
  const server = serverCards.get(nonce)
  if (!server) {
    if (nonce.startsWith('server-card-')) throw new DailyCardSyncUnavailable('Wait for this check-in to finish loading, then try again.')
    return
  }
  const state = cards.get(nonce)
  if (!state) throw new DailyCardSyncUnavailable('This check-in was cleared.')
  if (server.card.status === 'closed') {
    if (state.phase !== 'saved') throw new DailyCardSyncUnavailable('This check-in was finished in another window. Reopen Ask Mia.')
    return
  }
  const snapshot = JSON.parse(JSON.stringify(state)) as DailyCardState
  const next = server.queue.catch(() => undefined).then(async () => {
    if (serverCards.get(nonce) !== server || !entries.has(nonce)) throw new DailyCardSyncUnavailable('This check-in was cleared.')
    if (server.card.status === 'closed') {
      if (snapshot.phase !== 'saved') throw new DailyCardSyncUnavailable('This check-in was finished in another window. Reopen Ask Mia.')
      return
    }
    let result: Awaited<ReturnType<typeof updateChallengeChatCard>>
    try {
      result = await updateChallengeChatCard(server.card.id, { action: 'save_state', expected_lock_version: server.card.lock_version, state: snapshot })
    } catch (error) {
      // Another window saved this card first; the participant should reopen
      // Ask Mia to see the newer copy rather than a generic save failure.
      if (error instanceof ApiRequestError && error.status === 409) throw new DailyCardSyncUnavailable('This check-in changed in another window. Reopen Ask Mia.')
      throw error
    }
    if (serverCards.get(nonce) !== server || !entries.has(nonce)) throw new DailyCardSyncUnavailable('This check-in was cleared.')
    if (result.record.lock_version >= server.card.lock_version) server.card = result.record
    if (server.card.status === 'closed' && snapshot.phase !== 'saved') throw new DailyCardSyncUnavailable('This check-in was finished in another window. Reopen Ask Mia.')
  })
  server.queue = next
  return next
}

export type DailyCardHandoff = { nonce: string; rowId: number }

// Today and Ask Mia share the exact request identity and recoverable result.
// Persist before sending: a closed tab can reconcile an approval without
// restaging or saving the purchase twice.
export async function saveDailyCardPurchase(handoff: DailyCardHandoff, action: 'purchase_stage' | 'purchase_approve', input: DailyInput, mutate: DailyMutate, actor: DailyScope) {
  const { nonce, rowId } = handoff
  const state = readDailyCard(nonce)
  if (!state || !state.rows.some(row => row.id === rowId)) throw new DailyCardSyncUnavailable('Reopen Ask Mia before saving this purchase.')
  const step = `${action === 'purchase_stage' ? 'stage' : 'approve'}:${rowId}`
  const id = `${step}:${JSON.stringify(input)}`
  const key = state.keys[id] ?? crypto.randomUUID()
  writeDailyCard(nonce, current => ({ ...current, phase: 'idle', message: null, keys: { ...current.keys, [id]: key },
    rows: current.rows.map(row => row.id === rowId ? { ...row, status: 'unknown', ...(action === 'purchase_stage' ? { amount: String(Number(input.amount_cents) / 100), merchant: String(input.merchant), purchased_on: String(input.purchased_on) } : {}) } : row),
    unconfirmed: { action, input, key, rowId } }))
  await syncDailyCard(nonce)
  const record = await mutate(action, input, undefined, key)
  if (!readDailyCard(nonce)) throw new DailyCardSyncUnavailable('This check-in was cleared.')
  if (!record && readDailyRecovery(actor)?.key === key) return null
  writeDailyCard(nonce, current => ({ ...current, unconfirmed: undefined,
    rows: current.rows.map(row => row.id !== rowId ? row : record
      ? action === 'purchase_stage' ? { ...row, status: 'pending', draft: record as DailyPurchaseDraft }
        : { ...row, status: 'saved', purchaseId: row.draft?.savings_daily_purchase_id }
      : { ...row, status: 'failed', draft: undefined }),
    keys: !record ? Object.fromEntries(Object.entries(current.keys).filter(([name]) => !name.startsWith(`stage:${rowId}:`))) : current.keys }))
  await syncDailyCard(nonce)
  return record
}

export async function dismissDailyCard(nonce: string) {
  const server = serverCards.get(nonce)
  if (server) {
    await syncDailyCard(nonce)
    const result = await updateChallengeChatCard(server.card.id, { action: 'dismiss', expected_lock_version: server.card.lock_version })
    server.card = result.record
  }
  forgetDailyCard(nonce)
}

function persist(scope: string) {
  try {
    const saved = [...entries.values()].filter((entry) => entry.scope === scope && cards.has(entry.nonce)).map((entry) => {
      const state = cards.get(entry.nonce)!
      return state.phase === 'saved'
        ? { nonce: entry.nonce, report: { ...entry.report, feelings: null }, state: { ...state, rows: state.rows.map((row) => ({ ...row, draft: undefined })), keys: {}, feelingThen: '', feelingNow: '', unconfirmed: undefined } }
        : { nonce: entry.nonce, report: entry.report, state }
    })
    if (saved.length) sessionStorage.setItem(STORAGE_PREFIX + scope, JSON.stringify(saved))
    else sessionStorage.removeItem(STORAGE_PREFIX + scope)
  } catch { /* Without storage the card still works for this page; a reload then shows Today. */ }
}
export function registerDailyCard(entry: DailyCardEntry) { entries.set(entry.nonce, entry); if (cards.has(entry.nonce)) persist(entry.scope) }
export function readDailyCard(nonce: string): DailyCardState | undefined { return cards.get(nonce) }
export function writeDailyCard(nonce: string, update: (state: DailyCardState) => DailyCardState) {
  const current = cards.get(nonce)
  if (!current) return
  cards.set(nonce, update(current))
  const entry = entries.get(nonce)
  if (entry) persist(entry.scope)
  scheduleDailyCardSync(nonce)
  cardListeners.forEach((listener) => listener())
}
export function useDailyCard(nonce: string, init: () => DailyCardState): DailyCardState {
  if (!cards.has(nonce)) {
    cards.set(nonce, init())
    const entry = entries.get(nonce)
    if (entry) persist(entry.scope)
  }
  return useSyncExternalStore(subscribeCards, () => cards.get(nonce)!)
}
export function forgetDailyCard(nonce: string) {
  const entry = entries.get(nonce)
  clearTimeout(syncTimers.get(nonce)); syncTimers.delete(nonce)
  cards.delete(nonce); entries.delete(nonce); serverCards.delete(nonce)
  if (entry) persist(entry.scope)
}
// Cards saved for this exact participant, household and program in this tab.
// A request that was in flight when the page closed stays unconfirmed, so the
// card checks it before anything new is sent.
export function restoreDailyCards(scope: string): DailyCardEntry[] {
  try {
    const raw: unknown = JSON.parse(sessionStorage.getItem(STORAGE_PREFIX + scope) ?? '[]')
    if (!Array.isArray(raw)) return []
    return raw.flatMap((item) => {
      if (!item || typeof item.nonce !== 'string' || !item.report || !item.state || !Array.isArray(item.state.rows)) return []
      const state = item.state as DailyCardState
      if (!cards.has(item.nonce)) cards.set(item.nonce, { ...state, phase: state.phase === 'saving' ? 'idle' : state.phase,
        rows: state.rows.map((row) => row.status === 'saving' ? { ...row, status: state.unconfirmed?.rowId === row.id ? 'unknown' : 'pending' } : row) })
      const entry = { scope, report: item.report as DailyReportIntake, nonce: item.nonce }
      entries.set(item.nonce, entry)
      return [entry]
    })
  } catch { return [] }
}
export function reconcileServerDailyCards(scope: string, activeNonces: Set<string>) {
  for (const [nonce, entry] of [...entries]) {
    if (entry.scope === scope && nonce.startsWith('server-card-') && !activeNonces.has(nonce)) forgetDailyCard(nonce)
  }
}
export function clearDailyCards(scope?: string) {
  for (const [nonce, entry] of [...entries]) if (!scope || entry.scope === scope) { clearTimeout(syncTimers.get(nonce)); syncTimers.delete(nonce); entries.delete(nonce); cards.delete(nonce); serverCards.delete(nonce) }
  try {
    for (const key of Object.keys(sessionStorage)) if (key.startsWith(STORAGE_PREFIX) && (!scope || key === STORAGE_PREFIX + scope)) sessionStorage.removeItem(key)
  } catch { /* nothing stored */ }
}

// The newest Mia reply is a crisis or wellbeing-check reply (flagged by the
// server): no money prompt, chips or cards belong under it until the
// participant sends a new message that gets an ordinary reply.
export function latestReplyIsSafety(messages: { role: string; safety_reply?: boolean }[]): boolean {
  for (let index = messages.length - 1; index >= 0; index -= 1) if (messages[index].role === 'assistant') return messages[index].safety_reply === true
  return false
}
// True while a card holds progress that a new message must not wipe: some rows
// saved, staged or unconfirmed while others still need saving.
export function dailyCardNeedsAttention(nonce: string): boolean {
  const card = cards.get(nonce)
  if (!card || card.phase === 'saved') return false
  return Boolean(card.unconfirmed) || card.rows.some((row) => row.status === 'saved' || row.status === 'unknown' || row.status === 'saving' || row.draft !== undefined)
}

// A day is checked in once a spending or no-spend report is saved for it, the
// rule reminders and coaches use. Purchases alone, or staged ones, do not finish it.
export function dayCheckedIn(day: DailyDay): boolean {
  return day.checked_in ?? (day.spending_state === 'spending' || day.spending_state === 'no_spend')
}

export type TodayCheckIn = { context: DailyContext | null; checkedIn: boolean | null }

// Reads today's private daily context for the Mia check-in prompt and the
// Today shortcut. It never writes. Unknown (loading, closed, failed) is null.
export function useTodayCheckIn(scope: BaselineScope | undefined, cohortId: number | undefined, enabled: boolean, refreshKey: number): TodayCheckIn {
  const [loaded, setLoaded] = useState<{ key: string; context: DailyContext } | null>(null)
  const [focusKey, setFocusKey] = useState(0)
  const key = enabled && scope ? `${scope.user_id}:${scope.household_id}:${cohortId ?? ''}` : ''
  useEffect(() => {
    if (!key || !scope) return
    const controller = new AbortController()
    fetchDailyContext(undefined, controller.signal).then((context) => {
      if (dailyContextMatches(context, scope, cohortId)) setLoaded({ key, context })
      else setLoaded(null)
    }).catch(() => { if (!controller.signal.aborted) setLoaded(null) })
    return () => controller.abort()
    // scope is represented by key; a new object with the same IDs needs no reload.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, cohortId, refreshKey, focusKey])
  useEffect(() => {
    if (!key) return
    const refresh = () => { if (document.visibilityState === 'visible') setFocusKey((value) => value + 1) }
    window.addEventListener('focus', refresh)
    document.addEventListener('visibilitychange', refresh)
    return () => { window.removeEventListener('focus', refresh); document.removeEventListener('visibilitychange', refresh) }
  }, [key])
  const context = loaded && loaded.key === key ? loaded.context : null
  const day = context?.day
  const open = Boolean(context && day && context.calendar.phase === 'active' && day.local_on === context.calendar.local_today)
  return { context, checkedIn: open && day ? dayCheckedIn(day) : null }
}
