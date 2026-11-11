import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react'

export type CoachWorkspaceMutationTicket = {
  id: number
  workspaceId: number | null
}

export type CoachWorkspaceMutationLifecycle = {
  pending: boolean
  begin: () => CoachWorkspaceMutationTicket
  isCurrent: (ticket: CoachWorkspaceMutationTicket) => boolean
  finish: (ticket: CoachWorkspaceMutationTicket) => void
}

// Every save that must not outlive its program registers here, so the Admin side's program picker
// can lock while any of them is in flight.
let holds = 0
const holdListeners = new Set<() => void>()
const changeHolds = (delta: number) => { holds = Math.max(0, holds + delta); holdListeners.forEach(listener => listener()) }
const subscribeHolds = (listener: () => void) => { holdListeners.add(listener); return () => { holdListeners.delete(listener) } }

export function useWorkspaceMutationInFlight() {
  return useSyncExternalStore(subscribeHolds, () => holds > 0, () => false)
}

// For saves that are not tickets (a form, an invite): holds the program picker while `busy`.
export function useHoldWorkspaceLock(busy: boolean) {
  useEffect(() => {
    if (!busy) return
    changeHolds(1)
    return () => changeHolds(-1)
  }, [busy])
}

export function useCoachWorkspaceMutationLifecycle(activeWorkspaceId: number | null): CoachWorkspaceMutationLifecycle {
  const activeWorkspaceIdRef = useRef(activeWorkspaceId)
  const nextIdRef = useRef(0)
  const activeTicketsRef = useRef(new Set<number>())
  const [pendingCount, setPendingCount] = useState(0)

  useLayoutEffect(() => {
    activeWorkspaceIdRef.current = activeWorkspaceId
  }, [activeWorkspaceId])

  const begin = useCallback(() => {
    const ticket = { id: ++nextIdRef.current, workspaceId: activeWorkspaceIdRef.current }
    activeTicketsRef.current.add(ticket.id)
    changeHolds(1)
    setPendingCount(activeTicketsRef.current.size)
    return ticket
  }, [])

  const isCurrent = useCallback((ticket: CoachWorkspaceMutationTicket) => (
    activeTicketsRef.current.has(ticket.id) && ticket.workspaceId === activeWorkspaceIdRef.current
  ), [])

  const finish = useCallback((ticket: CoachWorkspaceMutationTicket) => {
    if (activeTicketsRef.current.delete(ticket.id)) changeHolds(-1)
    setPendingCount(activeTicketsRef.current.size)
  }, [])

  return useMemo(() => ({ pending: pendingCount > 0, begin, isCurrent, finish }), [begin, finish, isCurrent, pendingCount])
}
