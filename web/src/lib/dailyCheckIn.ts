import { useEffect, useState } from 'react'
import { fetchDailyContext } from '../api'
import type { BaselineScope } from './financialBaseline'
import { dailyContextMatches, type DailyContext, type DailyDay } from './dailyChallenge'

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
