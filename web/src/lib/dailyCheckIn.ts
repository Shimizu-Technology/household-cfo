import { useEffect, useState, useSyncExternalStore } from 'react'
import { fetchDailyContext } from '../api'
import type { BaselineScope } from './financialBaseline'
import { dailyContextMatches, type DailyAction, type DailyContext, type DailyDay, type DailyInput, type DailyPurchaseDraft } from './dailyChallenge'

// Mia daily report cards keep their progress here, outside the card component,
// so leaving Ask Mia and coming back restores staged drafts, request keys and
// saved rows instead of offering to save the same purchases again. In memory
// only: purchase details are never written to browser storage.
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
const cards = new Map<string, DailyCardState>()
const cardListeners = new Set<() => void>()
const subscribeCards = (listener: () => void) => { cardListeners.add(listener); return () => { cardListeners.delete(listener) } }
export function readDailyCard(nonce: string): DailyCardState | undefined { return cards.get(nonce) }
export function writeDailyCard(nonce: string, update: (state: DailyCardState) => DailyCardState) {
  const current = cards.get(nonce)
  if (!current) return
  cards.set(nonce, update(current))
  cardListeners.forEach((listener) => listener())
}
export function useDailyCard(nonce: string, init: () => DailyCardState): DailyCardState {
  if (!cards.has(nonce)) cards.set(nonce, init())
  return useSyncExternalStore(subscribeCards, () => cards.get(nonce)!)
}
export function forgetDailyCard(nonce: string) { cards.delete(nonce) }
// True while a card holds progress that a new message must not wipe: some rows
// saved, staged or unconfirmed while others still need saving.
export function dailyCardNeedsAttention(nonce: string): boolean {
  const card = cards.get(nonce)
  if (!card || card.phase === 'saved') return false
  const open = card.rows.filter((row) => row.status !== 'saved' && row.status !== 'moved')
  return open.length > 0 && card.rows.some((row) => row.status === 'saved' || row.status === 'unknown' || row.status === 'saving' || row.draft !== undefined)
}

// A day is checked in once the participant saved a purchase for it, or saved a
// spending or no-spend report. A saved "not checked" report is still unknown.
export function dayCheckedIn(day: DailyDay): boolean {
  return day.checked_in ?? (day.approved_purchase_count > 0 || day.spending_state === 'spending' || day.spending_state === 'no_spend')
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
