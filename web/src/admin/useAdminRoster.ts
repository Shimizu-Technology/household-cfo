import { useCallback, useEffect, useRef, useState } from 'react'
import { fetchAdminCohorts, fetchAdminUsers } from '../api'
import type { AdminCohort, AdminUser } from '../api'

// The groups and people a section works with. The server decides who is visible,
// so every section shows exactly what the signed-in person may manage.
export function useAdminRoster() {
  const [state, setState] = useState<{ groups: AdminCohort[]; people: AdminUser[] }>({ groups: [], people: [] })
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const sequence = useRef(0)

  const reload = useCallback(async () => {
    const mine = ++sequence.current
    setError(null)
    try {
      const [groups, people] = await Promise.all([fetchAdminCohorts(), fetchAdminUsers()])
      if (mine === sequence.current) setState({ groups, people })
    } catch (caught) {
      if (mine === sequence.current) setError(caught instanceof Error ? caught.message : 'We couldn’t load your people. Try again.')
    } finally {
      if (mine === sequence.current) setLoading(false)
    }
  }, [])

  useEffect(() => {
    queueMicrotask(() => void reload())
    return () => { sequence.current += 1 }
  }, [reload])

  return { ...state, loading, error, reload }
}

export function joinedCount(people: AdminUser[], groupId: number) {
  return people.filter(person => person.role === 'participant' && person.invitation_status === 'accepted' && person.cohorts.some(item => item.cohort.id === groupId && item.role === 'participant')).length
}
