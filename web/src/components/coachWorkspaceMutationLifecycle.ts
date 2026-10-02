import { useCallback, useLayoutEffect, useMemo, useRef, useState } from 'react'

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
    setPendingCount(activeTicketsRef.current.size)
    return ticket
  }, [])

  const isCurrent = useCallback((ticket: CoachWorkspaceMutationTicket) => (
    activeTicketsRef.current.has(ticket.id) && ticket.workspaceId === activeWorkspaceIdRef.current
  ), [])

  const finish = useCallback((ticket: CoachWorkspaceMutationTicket) => {
    activeTicketsRef.current.delete(ticket.id)
    setPendingCount(activeTicketsRef.current.size)
  }, [])

  return useMemo(() => ({ pending: pendingCount > 0, begin, isCurrent, finish }), [begin, finish, isCurrent, pendingCount])
}
