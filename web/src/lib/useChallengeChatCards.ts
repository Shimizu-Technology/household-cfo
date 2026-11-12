import { useCallback, useEffect, useRef, useState } from 'react'
import { fetchChallengeChatCards } from '../api'
import type { BaselineScope } from './financialBaseline'
import type { ChallengeChatCard } from './challengeChatCards'
import { clearDailyCards, forgetDailyCard, reconcileServerDailyCards, registerServerDailyCard, type DailyCardEntry } from './dailyCheckIn'

export function useChallengeChatCards(enabled: boolean, scope: string, actor: BaselineScope | undefined, cohortId: number | undefined, refreshKey?: string) {
  const [loaded, setLoaded] = useState<{ scope: string; cards: ChallengeChatCard[]; reports: DailyCardEntry[] } | null>(null)
  const [readError, setReadError] = useState<string | null>(null)
  const [attempt, setAttempt] = useState(0)
  const revision = useRef(0)
  const changed = useRef(new Map<number, number>())
  const cleared = useRef(0)
  const accept = useCallback((card: ChallengeChatCard) => {
    if (!actor || !cohortId) return false
    changed.current.set(card.id, ++revision.current)
    if (card.status === 'closed') {
      forgetDailyCard(`server-card-${card.id}`)
      setLoaded(current => current?.scope === scope ? { ...current, cards: current.cards.filter(row => row.id !== card.id), reports: current.reports.filter(row => row.nonce !== `server-card-${card.id}`) } : current)
      return true
    }
    const report = registerServerDailyCard(card, scope)
    setLoaded(current => ({ scope, cards: [...(current?.scope === scope ? current.cards.filter(row => row.id !== card.id && !(['goal', 'leave'].includes(card.kind) && row.kind === card.kind)) : []), card], reports: [...(current?.scope === scope ? current.reports.filter(row => row.nonce !== report?.nonce) : []), ...(report ? [report] : [])] }))
    return true
  }, [scope, actor, cohortId])
  useEffect(() => {
    if (!enabled || !actor || !cohortId) return
    const controller = new AbortController()
    const startRevision = revision.current
    const startClear = cleared.current
    fetchChallengeChatCards(controller.signal).then(result => {
      if (controller.signal.aborted || startClear !== cleared.current || result.cohort_id !== cohortId || result.actor_scope.user_id !== actor.user_id || result.actor_scope.household_id !== actor.household_id) return
      setReadError(null)
      const reports = result.records.flatMap(card => { const report = registerServerDailyCard(card, scope); return report ? [report] : [] })
      setLoaded(current => {
        const newer = current?.scope === scope ? current.cards.filter(card => (changed.current.get(card.id) ?? 0) > startRevision) : []
        const cards = [...result.records.filter(card => (changed.current.get(card.id) ?? 0) <= startRevision), ...newer]
        const activeNonces = new Set(cards.filter(card => card.kind === 'daily_report').map(card => `server-card-${card.id}`))
        reconcileServerDailyCards(scope, activeNonces)
        return { scope, cards, reports: [...reports.filter(report => activeNonces.has(report.nonce) && !newer.some(card => report.nonce === `server-card-${card.id}`)), ...(current?.scope === scope ? current.reports.filter(report => newer.some(card => report.nonce === `server-card-${card.id}`)) : [])] }
      })
    }).catch(() => { if (!controller.signal.aborted && startClear === cleared.current) setReadError(scope) })
    return () => controller.abort()
  }, [enabled, scope, actor, cohortId, attempt, refreshKey])
  const remove = useCallback((id: number) => {
    changed.current.set(id, ++revision.current)
    forgetDailyCard(`server-card-${id}`)
    setLoaded(current => current?.scope === scope ? { ...current, cards: current.cards.filter(card => card.id !== id), reports: current.reports.filter(report => report.nonce !== `server-card-${id}`) } : current)
  }, [scope])
  const clear = useCallback(() => {
    cleared.current += 1
    setReadError(null)
    clearDailyCards(scope)
    setLoaded({ scope, cards: [], reports: [] })
  }, [scope])
  return { accept, remove, clear, readFailed: enabled && readError === scope, retry: () => setAttempt(value => value + 1), reports: loaded?.scope === scope ? loaded.reports : [], savings: loaded?.scope === scope ? loaded.cards.filter(card => card.kind === 'savings' && card.status === 'pending') : [], leaves: loaded?.scope === scope ? loaded.cards.filter(card => card.kind === 'leave' && card.status === 'pending') : [], goals: loaded?.scope === scope ? loaded.cards.filter(card => card.kind === 'goal' && card.status === 'pending') : [] }
}
