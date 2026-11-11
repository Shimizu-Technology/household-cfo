import { useState } from 'react'
import { cancelAdminUserInvitation, removeCoachGroupParticipant, resendAdminUserInvitation, updateAdminUser } from '../../api'
import type { AdminUser, CurrentUser, UserRole } from '../../api'
import { Button } from '../../components/Button'
import { useHoldWorkspaceLock } from '../../components/coachWorkspaceMutationLifecycle'
import { useAuthContext } from '../../contexts/authContextValue'
import { confirmAction } from '../../lib/confirmAction'
import { AdminDialog } from '../AdminDialog'
import { inviteStateLabel, inviteStateOf, lastActiveAt, lastActiveWords, roleLabel, setupWords, shortDay } from '../adminWords'
import type { RosterGroup } from '../useAdminRoster'

const message = (caught: unknown, fallback: string) => caught instanceof Error ? caught.message : fallback

// One person: how they are doing, and the few things a coach may do about it.
export function PersonDetail({ person, groups, currentUser, onClose, onChanged, onRemoved }: {
  person: AdminUser
  groups: RosterGroup[]
  currentUser: CurrentUser
  onClose: () => void
  onChanged: () => Promise<void> | void
  // The person is no longer in the list (their invitation was cancelled), so the page says what happened.
  onRemoved: (notice: string) => void
}) {
  const { activeCoachWorkspaceId } = useAuthContext()
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [otherGroup, setOtherGroup] = useState('')
  const [role, setRole] = useState<UserRole>(person.role)
  useHoldWorkspaceLock(busy)
  const state = inviteStateOf(person)
  const isSelf = person.id === currentUser.id
  const isParticipant = person.role === 'participant'
  const memberships = person.cohorts
  const otherGroups = groups.filter(group => !memberships.some(item => item.cohort.id === group.id))
  const activeAt = lastActiveAt(person)
  const name = person.full_name || person.email
  const waiting = isParticipant && (state === 'invited' || state === 'bounced')

  // An administrator with no program chosen names the group's own program, so removing never fails
  // with a message about choosing one. With nothing to name, the button is not offered.
  const platformMode = currentUser.is_admin && activeCoachWorkspaceId === null
  const programOf = (groupId: number) => groups.find(group => group.id === groupId)?.detail?.coach_workspace_id
  const programFor = (groupIds: number[]) => {
    const ids = [...new Set(groupIds.map(programOf))]
    return ids.length === 1 && ids[0] !== undefined ? ids[0] : undefined
  }
  const canChangeGroups = !platformMode || programFor(memberships.map(item => item.cohort.id)) !== undefined

  async function run(action: () => Promise<string>) {
    if (busy) return
    setBusy(true); setError(null); setNotice(null)
    try {
      const done = await action()
      await onChanged()
      setNotice(done)
    } catch (caught) { setError(message(caught, 'That didn’t go through. Try again.')) }
    finally { setBusy(false) }
  }

  const resend = () => run(async () => {
    const response = await resendAdminUserInvitation(person.id)
    return response.invitation_sent ? 'Invitation sent again.' : 'The email still didn’t send. Check the address, then try again in a minute.'
  })
  const addToGroup = () => run(async () => {
    await updateAdminUser(person.id, { cohort_ids: [...memberships.map(item => item.cohort.id), Number(otherGroup)] })
    setOtherGroup('')
    return `Added to ${groups.find(group => String(group.id) === otherGroup)?.name ?? 'the new group'}.`
  })
  // Only for someone in exactly one group, so "move" cannot quietly drop a second group.
  const moveToGroup = () => run(async () => {
    await updateAdminUser(person.id, { cohort_ids: [Number(otherGroup)] })
    setOtherGroup('')
    return `Moved to ${groups.find(group => String(group.id) === otherGroup)?.name ?? 'the new group'}.`
  })
  const saveRole = () => run(async () => { await updateAdminUser(person.id, { role }); return `Now a ${roleLabel[role].toLowerCase()}.` })
  const restore = () => run(async () => {
    await updateAdminUser(person.id, { invitation_status: 'pending', ...(isParticipant ? { cohort_ids: [Number(otherGroup)] } : {}) })
    setOtherGroup('')
    return 'Access restored. They can sign in again.'
  })
  async function removeFromGroup(membership: AdminUser['cohorts'][number]) {
    const ok = await confirmAction('They will lose this group’s experience. Their account and other groups stay.', { title: `Remove ${name} from ${membership.cohort.name}?`, confirmLabel: 'Remove', cancelLabel: 'Keep them', caution: true })
    if (ok) void run(async () => { await removeCoachGroupParticipant(membership.cohort.id, person.id, membership.id, platformMode ? programOf(membership.cohort.id) : undefined); return `Removed from ${membership.cohort.name}.` })
  }
  async function cancelInvitation() {
    const ok = await confirmAction('They will not be able to join with the email they were sent. You can invite them again any time.', { title: `Cancel the invitation for ${name}?`, confirmLabel: 'Cancel invitation', cancelLabel: 'Keep it', caution: true })
    if (!ok || busy) return
    setBusy(true); setError(null); setNotice(null)
    try {
      await cancelAdminUserInvitation(person.id, platformMode ? programFor(memberships.map(item => item.cohort.id)) : undefined)
      await onChanged()
      onRemoved(`The invitation for ${name} was cancelled.`)
    } catch (caught) { setError(message(caught, 'That didn’t go through. Try again.')); setBusy(false) }
  }
  async function removeAccess() {
    const ok = await confirmAction('They will no longer be able to sign in to Household CFO.', { title: `Remove ${name}?`, confirmLabel: 'Remove', cancelLabel: 'Keep them', caution: true })
    if (ok) void run(async () => { await updateAdminUser(person.id, { invitation_status: 'revoked', cohort_ids: [] }); return 'Removed.' })
  }

  return <AdminDialog title={name} labelId="admin-person-title" onClose={onClose}>
    <dl className="admin-facts">
      <div><dt>Email</dt><dd>{person.email}</dd></div>
      <div><dt>Group</dt><dd>{memberships.map(item => item.cohort.name).join(', ') || (person.role === 'admin' ? 'All groups' : 'No group yet')}</dd></div>
      <div><dt>Role</dt><dd>{roleLabel[person.role]}</dd></div>
      <div><dt>Invitation</dt><dd>{inviteStateLabel[state]}{state === 'invited' && person.invited_at ? ` · sent ${shortDay(person.invited_at)}` : ''}</dd></div>
      {state === 'bounced' && person.invite_email.error && <div><dt>What happened</dt><dd>{person.invite_email.error}</dd></div>}
      <div><dt>Last active</dt><dd>{lastActiveWords(activeAt)}</dd></div>
      {isParticipant && <div><dt>Setup</dt><dd>{setupWords(person)}</dd></div>}
    </dl>
    {error && <p className="admin-alert error" role="alert">{error}</p>}
    {notice && <p className="admin-alert success" role="status">{notice}</p>}

    {isSelf && <p className="admin-muted">This is you. Another admin can change your role or access.</p>}
    {!isSelf && <div className="admin-detail-actions">
      {person.can_resend_invitation && state !== 'removed' && <Button disabled={busy} onClick={() => void resend()}>Send the invitation again</Button>}

      {state !== 'removed' && isParticipant && otherGroups.length > 0 && <div className="admin-inline-form">
        <label className="admin-field"><span>{memberships.length === 0 ? 'Put in a group' : 'Another group'}</span>
          <select value={otherGroup} disabled={busy} onChange={event => setOtherGroup(event.target.value)}><option value="">Choose a group</option>{otherGroups.map(group => <option key={group.id} value={group.id}>{group.name}</option>)}</select>
        </label>
        <Button variant="secondary" disabled={busy || !otherGroup} onClick={() => void addToGroup()}>Add to this group</Button>
        {memberships.length === 1 && <Button variant="secondary" disabled={busy || !otherGroup} onClick={() => void moveToGroup()}>{`Move here, out of ${memberships[0].cohort.name}`}</Button>}
      </div>}

      {currentUser.is_admin && state !== 'removed' && <div className="admin-inline-form">
        <label className="admin-field"><span>Role</span>
          <select value={role} disabled={busy} onChange={event => setRole(event.target.value as UserRole)}>{(['participant', 'coach', 'admin'] as UserRole[]).map(value => <option key={value} value={value}>{roleLabel[value]}</option>)}</select>
        </label>
        <Button variant="secondary" disabled={busy || role === person.role} onClick={() => void saveRole()}>Change role</Button>
      </div>}

      {currentUser.is_admin && state === 'removed' && <div className="admin-inline-form">
        {isParticipant && <label className="admin-field"><span>Return to group</span>
          <select value={otherGroup} disabled={busy} onChange={event => setOtherGroup(event.target.value)}><option value="">Choose a group</option>{groups.map(group => <option key={group.id} value={group.id}>{group.name}</option>)}</select>
        </label>}
        <Button variant="secondary" disabled={busy || (isParticipant && !otherGroup)} onClick={() => void restore()}>Restore access</Button>
      </div>}

      {/* Someone who has not joined has nothing to remove from: the invitation itself is what is cancelled. */}
      {waiting && canChangeGroups && <Button variant="danger" disabled={busy} onClick={() => void cancelInvitation()}>Cancel the invitation</Button>}
      {state !== 'removed' && isParticipant && canChangeGroups && (!waiting || memberships.length > 1) && memberships.map(item => <Button key={item.id} variant="danger" disabled={busy} onClick={() => void removeFromGroup(item)}>{memberships.length > 1 ? `Remove from ${item.cohort.name}` : 'Remove from group'}</Button>)}
      {state !== 'removed' && isParticipant && !canChangeGroups && <p className="admin-muted">Choose a program at the top of the page to remove this person.</p>}
      {currentUser.is_admin && state !== 'removed' && !isParticipant && <Button variant="danger" disabled={busy} onClick={() => void removeAccess()}>Remove access</Button>}
    </div>}
  </AdminDialog>
}
