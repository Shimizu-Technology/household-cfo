import { useState } from 'react'
import { ApiRequestError, joinPreviewSeat, leavePreviewSeat } from '../api'
import type { CurrentUser } from '../api'
import { confirmAction } from '../lib/confirmAction'
import { setPreviewGroups, usePreviewGroups } from '../lib/previewGroups'
import './UseAppAs.css'

type Props = {
  user: CurrentUser
  // The group the app is showing now; undefined means the person's own household.
  currentCohortId?: number
  onChooseHousehold: () => void
  onChooseGroup: (cohortId: number) => void
}

// Staff use the same app a participant does. This is how they choose whose
// experience to try: their own household, or a group (a preview seat that the
// program never counts).
export function UseAppAs({ user, currentCohortId, onChooseHousehold, onChooseGroup }: Props) {
  const groups = usePreviewGroups(user)
  const [busyId, setBusyId] = useState<number | 'household' | null>(null)
  const [message, setMessage] = useState<{ tone: 'error' | 'info'; text: string } | null>(null)
  if (groups.length === 0) return null

  async function choose(cohortId: number) {
    if (busyId !== null || cohortId === currentCohortId) return
    setBusyId(cohortId)
    setMessage(null)
    try {
      const group = groups.find(item => item.cohort_id === cohortId)
      if (group && !group.seated) setPreviewGroups(user.id, (await joinPreviewSeat(cohortId)).preview_groups)
      onChooseGroup(cohortId)
    } catch (error) {
      setMessage({ tone: 'error', text: error instanceof ApiRequestError && error.status === 404 ? 'That group is no longer available to preview.' : 'We couldn’t switch to that group. Nothing changed. Try again.' })
    } finally { setBusyId(null) }
  }

  async function leave(cohortId: number, name: string) {
    if (busyId !== null) return
    const group = groups.find(item => item.cohort_id === cohortId)
    const confirmed = await confirmAction(
      group?.challenge_joined
        ? `This ends your savings challenge preview in ${name}. Your own household isn’t changed.`
        : `You’ll stop using the app as ${name}. Your own household isn’t changed.`,
      { title: `Leave ${name}?`, confirmLabel: 'Leave preview', cancelLabel: 'Stay', caution: true })
    if (!confirmed) return
    setBusyId(cohortId)
    setMessage(null)
    try {
      const result = await leavePreviewSeat(cohortId)
      setPreviewGroups(user.id, result.preview_groups)
      if (cohortId === currentCohortId) onChooseHousehold()
      setMessage({ tone: 'info', text: result.message ?? 'You left this group’s preview.' })
    } catch {
      setMessage({ tone: 'error', text: 'We couldn’t leave that group. Nothing changed. Try again.' })
    } finally { setBusyId(null) }
  }

  const choices = [{ id: null as number | null, name: 'My household', note: 'Your own money, no group' }, ...groups.map(group => ({ id: group.cohort_id as number | null, name: group.name, note: !group.available ? 'No longer available' : group.seated ? 'Preview' : group.program_name }))]
  return <fieldset className="use-app-as" disabled={busyId !== null}>
    <legend>Use the app as</legend>
    {choices.map(choice => {
      const selected = choice.id === null ? currentCohortId === undefined : choice.id === currentCohortId
      const group = choice.id === null ? null : groups.find(item => item.cohort_id === choice.id)
      return <div key={choice.id ?? 'household'} className={`use-app-as-row${selected ? ' is-selected' : ''}`}>
        <label>
          <input type="radio" name="use-app-as" checked={selected} disabled={group?.available === false} onChange={() => choice.id === null ? onChooseHousehold() : void choose(choice.id)} />
          <span><strong>{choice.name}</strong><small>{choice.note}</small></span>
        </label>
        {group?.seated && <button type="button" className="use-app-as-leave" aria-label={group.available ? undefined : `No longer available. Leave ${group.name}`} onClick={() => void leave(group.cohort_id, group.name)}>Leave</button>}
      </div>
    })}
    {selectedGroupLine(groups, currentCohortId) && <p className="use-app-as-now" role="status">{selectedGroupLine(groups, currentCohortId)}</p>}
    {message && <p className={`use-app-as-message${message.tone === 'error' ? ' is-error' : ''}`} role={message.tone === 'error' ? 'alert' : 'status'}>{message.text}</p>}
  </fieldset>
}

function selectedGroupLine(groups: ReturnType<typeof usePreviewGroups>, currentCohortId?: number) {
  const group = groups.find(item => item.cohort_id === currentCohortId)
  return group ? `Using: ${group.name} · Preview` : null
}
