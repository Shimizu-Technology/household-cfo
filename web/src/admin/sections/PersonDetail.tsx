import { useState } from 'react'
import { removeCoachGroupParticipant, resendAdminUserInvitation, updateAdminUser } from '../../api'
import type { AdminCohort, AdminUser, CurrentUser, UserRole } from '../../api'
import { Button } from '../../components/Button'
import { confirmAction } from '../../lib/confirmAction'
import { AdminDialog } from '../AdminDialog'
import { inviteStateLabel, inviteStateOf, lastActiveAt, lastActiveWords, roleLabel, setupWords, shortDay } from '../adminWords'

const message = (caught: unknown, fallback: string) => caught instanceof Error ? caught.message : fallback

// One person: how they are doing, and the few things a coach may do about it.
export function PersonDetail({ person, groups, currentUser, onClose, onChanged }: {
  person: AdminUser
  groups: AdminCohort[]
  currentUser: CurrentUser
  onClose: () => void
  onChanged: () => Promise<void> | void
}) {
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [moveTo, setMoveTo] = useState('')
  const [role, setRole] = useState<UserRole>(person.role)
  const state = inviteStateOf(person)
  const isSelf = person.id === currentUser.id
  const isParticipant = person.role === 'participant'
  const memberships = person.cohorts
  const otherGroups = groups.filter(group => !memberships.some(item => item.cohort.id === group.id))
  const activeAt = lastActiveAt(person)

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
  const move = () => run(async () => {
    await updateAdminUser(person.id, { cohort_ids: [Number(moveTo)] })
    setMoveTo('')
    return `Moved to ${groups.find(group => String(group.id) === moveTo)?.name ?? 'the new group'}.`
  })
  const saveRole = () => run(async () => { await updateAdminUser(person.id, { role }); return `Now a ${roleLabel[role].toLowerCase()}.` })
  const restore = () => run(async () => {
    await updateAdminUser(person.id, { invitation_status: 'pending', ...(isParticipant ? { cohort_ids: [Number(moveTo)] } : {}) })
    setMoveTo('')
    return 'Access restored. They can sign in again.'
  })
  async function removeFromGroup(membership: AdminUser['cohorts'][number]) {
    const ok = await confirmAction('They will lose this group’s experience. Their account and other groups stay.', { title: `Remove ${person.full_name || person.email} from ${membership.cohort.name}?`, confirmLabel: 'Remove', cancelLabel: 'Keep them', caution: true })
    if (ok) void run(async () => { await removeCoachGroupParticipant(membership.cohort.id, person.id, membership.id); return `Removed from ${membership.cohort.name}.` })
  }
  async function removeAccess() {
    const ok = await confirmAction('They will no longer be able to sign in to Household CFO.', { title: `Remove ${person.full_name || person.email}?`, confirmLabel: 'Remove', cancelLabel: 'Keep them', caution: true })
    if (ok) void run(async () => { await updateAdminUser(person.id, { invitation_status: 'revoked', cohort_ids: [] }); return 'Removed.' })
  }

  return <AdminDialog title={person.full_name || person.email} labelId="admin-person-title" onClose={onClose}>
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
        <label className="admin-field"><span>Move to another group</span>
          <select value={moveTo} disabled={busy} onChange={event => setMoveTo(event.target.value)}><option value="">Choose a group</option>{otherGroups.map(group => <option key={group.id} value={group.id}>{group.name}</option>)}</select>
        </label>
        <Button variant="secondary" disabled={busy || !moveTo} onClick={() => void move()}>Move</Button>
      </div>}

      {currentUser.is_admin && state !== 'removed' && <div className="admin-inline-form">
        <label className="admin-field"><span>Role</span>
          <select value={role} disabled={busy} onChange={event => setRole(event.target.value as UserRole)}>{(['participant', 'coach', 'admin'] as UserRole[]).map(value => <option key={value} value={value}>{roleLabel[value]}</option>)}</select>
        </label>
        <Button variant="secondary" disabled={busy || role === person.role} onClick={() => void saveRole()}>Change role</Button>
      </div>}

      {currentUser.is_admin && state === 'removed' && <div className="admin-inline-form">
        {isParticipant && <label className="admin-field"><span>Return to group</span>
          <select value={moveTo} disabled={busy} onChange={event => setMoveTo(event.target.value)}><option value="">Choose a group</option>{groups.map(group => <option key={group.id} value={group.id}>{group.name}</option>)}</select>
        </label>}
        <Button variant="secondary" disabled={busy || (isParticipant && !moveTo)} onClick={() => void restore()}>Restore access</Button>
      </div>}

      {state !== 'removed' && isParticipant && memberships.map(item => <Button key={item.id} variant="danger" disabled={busy} onClick={() => void removeFromGroup(item)}>{memberships.length > 1 ? `Remove from ${item.cohort.name}` : 'Remove'}</Button>)}
      {currentUser.is_admin && state !== 'removed' && !isParticipant && <Button variant="danger" disabled={busy} onClick={() => void removeAccess()}>Remove access</Button>}
    </div>}
  </AdminDialog>
}
