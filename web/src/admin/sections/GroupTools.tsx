import { useCallback, useEffect, useRef, useState } from 'react'
import { fetchAdminPersonaAssignableCohorts } from '../../api'
import type { AdminPersonaAssignableCohort } from '../../api'
import { Button } from '../../components/Button'
import { CohortExperienceStudio } from '../../components/CohortExperienceStudio'
import { useCoachWorkspaceMutationLifecycle } from '../../components/coachWorkspaceMutationLifecycle'
import { useAuthContext } from '../../contexts/authContextValue'
import './sections.css'

// The tools people can open in a group. Used on a group's own page (one group) and under Coaching
// (a choice of the groups this person may see), so every role the server allows has a way in. What
// each role may do inside comes from the server, group by group.
export function GroupTools({ groupId, onDirtyChange }: { groupId?: number; onDirtyChange: (dirty: boolean) => void }) {
  const { activeCoachWorkspaceId } = useAuthContext()
  const lifecycle = useCoachWorkspaceMutationLifecycle(activeCoachWorkspaceId)
  const [cohorts, setCohorts] = useState<AdminPersonaAssignableCohort[]>([])
  const [state, setState] = useState<'loading' | 'ready' | 'failed'>('loading')
  const [selected, setSelected] = useState<number | null>(groupId ?? null)
  const request = useRef(0)

  const load = useCallback(async () => {
    const mine = ++request.current
    setState('loading')
    try {
      const next = await fetchAdminPersonaAssignableCohorts()
      if (mine !== request.current) return
      setCohorts(next); setState('ready')
    } catch {
      if (mine === request.current) setState('failed')
    }
  }, [])
  useEffect(() => {
    queueMicrotask(() => void load())
    return () => { request.current += 1 }
  }, [load])

  const shown = groupId === undefined ? cohorts : cohorts.filter(item => item.id === groupId)
  if (state === 'loading') return <p role="status" className="admin-muted">Opening the tools…</p>
  if (state === 'failed') return <div className="admin-empty"><p role="alert">The tools couldn’t be opened.</p><Button variant="secondary" onClick={() => void load()}>Try again</Button></div>
  if (shown.length === 0) return <div className="admin-empty"><p>{groupId === undefined ? 'There are no groups for you to set tools for yet. A program owner can add you to one.' : 'The tools for this group aren’t available to you.'}</p></div>
  return <div className="admin-tools">
    <CohortExperienceStudio fixedGroup={groupId !== undefined} cohorts={shown} cohortsLoading={false} selectedCohortId={selected} onSelectedCohortIdChange={setSelected} mutationLifecycle={lifecycle} onDirtyChange={onDirtyChange} />
  </div>
}
