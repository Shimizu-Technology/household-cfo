import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { fetchAdminCohorts, fetchAdminPersonaAssignableCohorts, fetchAdminUsers } from '../api'
import type { AdminCohort, AdminCohortStatus, AdminUser, CurrentUser } from '../api'
import { adminSectionsOf } from '../lib/appRoutes'

// A group as every role may see it: enough to choose it and read its people. Roles that manage
// the program also get its full details.
export type RosterGroup = { id: number; name: string; status: AdminCohortStatus; savingsChallenge: boolean; detail: AdminCohort | null }

const asRosterGroup = (group: AdminCohort): RosterGroup => ({ id: group.id, name: group.name, status: group.status, savingsChallenge: group.savings_challenge?.enabled === true, detail: group }) satisfies RosterGroup

// What this person may read. The server's own section list decides; owner-only endpoints are never
// called for anyone else, so an editor or reviewer never meets a "program owner access required" banner.
export function rosterAccess(user: CurrentUser) {
  const keys = new Set(adminSectionsOf(user).map(section => section.key))
  return { people: keys.has('people'), groups: keys.has('groups') }
}

// The groups and people a section works with.
export function useAdminRoster(currentUser: CurrentUser) {
  const access = rosterAccess(currentUser)
  const [state, setState] = useState<{ groups: RosterGroup[]; people: AdminUser[] }>({ groups: [], people: [] })
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const sequence = useRef(0)

  const reload = useCallback(async () => {
    const mine = ++sequence.current
    setError(null)
    try {
      const [groups, people] = await Promise.all([
        access.groups
          ? fetchAdminCohorts().then(items => items.map(asRosterGroup))
          : fetchAdminPersonaAssignableCohorts().then(items => items.map((item): RosterGroup => ({ id: item.id, name: item.name, status: item.status, savingsChallenge: item.savings_challenge_enabled === true, detail: null }))),
        access.people ? fetchAdminUsers() : Promise.resolve([] as AdminUser[]),
      ])
      if (mine === sequence.current) setState({ groups, people })
    } catch (caught) {
      if (mine === sequence.current) setError(caught instanceof Error ? caught.message : 'We couldn’t load your people. Try again.')
    } finally {
      if (mine === sequence.current) setLoading(false)
    }
  }, [access.groups, access.people])

  useEffect(() => {
    queueMicrotask(() => void reload())
    return () => { sequence.current += 1 }
  }, [reload])

  const details = useMemo(() => state.groups.flatMap(group => group.detail ? [group.detail] : []), [state.groups])
  return { ...state, details, access, loading, error, reload }
}

export function joinedCount(people: AdminUser[], groupId: number) {
  return people.filter(person => person.role === 'participant' && person.invitation_status === 'accepted' && person.cohorts.some(item => item.cohort.id === groupId && item.role === 'participant')).length
}
