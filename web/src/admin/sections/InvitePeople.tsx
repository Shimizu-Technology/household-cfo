import { useState, type FormEvent } from 'react'
import { ApiRequestError, createAdminUser } from '../../api'
import type { AdminUser, CurrentUser, UserRole } from '../../api'
import { Button } from '../../components/Button'
import { useHoldWorkspaceLock } from '../../components/coachWorkspaceMutationLifecycle'
import { confirmAction } from '../../lib/confirmAction'
import { MAX_INVITES_AT_ONCE, parseInviteEmails } from '../../lib/inviteEmails'
import { AdminDialog } from '../AdminDialog'
import { roleLabel } from '../adminWords'
import type { RosterGroup } from '../useAdminRoster'

type Result = { added: string[]; already: string[]; unsent: string[]; problems: string[] }

// One way to invite: paste one or many emails, choose a group (and a role, for admins). A group is only
// preselected when it is the only one, so a long list of emails never goes to the wrong group by default.
export function InvitePeople({ currentUser, groups, people, defaultGroupId, onClose, onDone }: {
  currentUser: CurrentUser
  groups: RosterGroup[]
  people: AdminUser[]
  defaultGroupId: number | null
  onClose: () => void
  onDone: () => void
}) {
  const [text, setText] = useState('')
  const [groupId, setGroupId] = useState<string>(String(defaultGroupId ?? (groups.length === 1 ? groups[0].id : '')))
  const groupName = groups.find(group => String(group.id) === groupId)?.name
  const [role, setRole] = useState<UserRole>('participant')
  const [sendEmail, setSendEmail] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [result, setResult] = useState<Result | null>(null)
  const needsGroup = role !== 'admin'
  const parsed = parseInviteEmails(text)
  useHoldWorkspaceLock(busy)

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (busy) return
    if (parsed.emails.length === 0) { setError('Type or paste at least one email address.'); return }
    if (parsed.emails.length > MAX_INVITES_AT_ONCE) { setError(`Invite up to ${MAX_INVITES_AT_ONCE} people at a time.`); return }
    if (needsGroup && !groupId) { setError('Choose which group they are joining.'); return }
    const count = parsed.emails.length
    const who = `${count} ${count === 1 ? 'person' : 'people'}`
    const confirmed = await confirmAction(sendEmail ? `Each of them gets an email invitation now.` : 'No email is sent now. You can send it later from People.', {
      title: needsGroup && groupName ? `Invite ${who} to ${groupName}?` : `Invite ${who} as ${roleLabel[role].toLowerCase()}s?`, confirmLabel: 'Invite', cancelLabel: 'Not yet',
    })
    if (!confirmed) return
    setBusy(true); setError(null)
    const outcome: Result = { added: [], already: [], unsent: [], problems: [] }
    const inGroup = new Set(people.filter(person => person.cohorts.some(item => String(item.cohort.id) === groupId)).map(person => person.email.toLowerCase()))
    for (const email of parsed.emails) {
      if (needsGroup && inGroup.has(email)) { outcome.already.push(email); continue }
      try {
        const response = await createAdminUser({ email, role, cohort_id: needsGroup ? groupId : undefined, send_invitation_email: sendEmail })
        if (response.already_invited && !response.invitation_sent) outcome.already.push(email)
        else {
          outcome.added.push(email)
          if (sendEmail && response.invitation_status === 'failed') outcome.unsent.push(email)
        }
      } catch (caught) {
        outcome.problems.push(`${email}: ${caught instanceof ApiRequestError || caught instanceof Error ? caught.message : 'This invitation could not be saved.'}`)
      }
    }
    setBusy(false)
    setResult(outcome)
    if (outcome.added.length > 0) onDone()
  }

  const staffRoles: UserRole[] = ['participant', 'coach', 'admin']
  return <AdminDialog title="Invite people" labelId="admin-invite-title" onClose={onClose}>
    {result ? <div className="admin-invite-result" role="status">
      <p className="admin-result-headline">{result.added.length === 0 ? 'No one new was invited.' : `${result.added.length} ${result.added.length === 1 ? 'person' : 'people'} invited.`}</p>
      {result.unsent.length > 0 && <p>The email didn’t go out for {result.unsent.join(', ')}. Open them in People and choose Send the invitation again.</p>}
      {result.already.length > 0 && <p>Already in this group: {result.already.join(', ')}.</p>}
      {result.problems.length > 0 && <div role="alert"><p>These didn’t work:</p><ul>{result.problems.map(item => <li key={item}>{item}</li>)}</ul></div>}
      <div className="admin-actions"><Button onClick={onClose}>Done</Button></div>
    </div> : <form className="admin-stack" onSubmit={submit} noValidate>
      <label className="admin-field wide"><span>Email addresses</span>
        <textarea rows={4} autoFocus value={text} placeholder={'name@example.com\nanother@example.com'} onChange={event => { setText(event.target.value); setError(null) }} />
        <small>One or many. Separate them with commas, spaces or new lines.</small>
      </label>
      {text.trim() && <p className="admin-count-line">{parsed.emails.length} {parsed.emails.length === 1 ? 'address' : 'addresses'} ready{parsed.problems.length > 0 ? ` · ${parsed.problems.length} to check` : ''}</p>}
      {parsed.problems.length > 0 && <ul className="admin-problem-list">{parsed.problems.map(item => <li key={item}>{item}</li>)}</ul>}
      {currentUser.is_admin && <label className="admin-field"><span>They will be</span>
        <select value={role} onChange={event => setRole(event.target.value as UserRole)}>{staffRoles.map(value => <option key={value} value={value}>{roleLabel[value]}</option>)}</select>
      </label>}
      {needsGroup && <label className="admin-field"><span>Group</span>
        <select value={groupId} onChange={event => setGroupId(event.target.value)}>
          <option value="">Choose a group</option>
          {groups.map(group => <option key={group.id} value={group.id}>{group.name}</option>)}
        </select>
      </label>}
      <label className="admin-inline-check wide"><input type="checkbox" checked={sendEmail} onChange={event => setSendEmail(event.target.checked)} /><span>Email them an invitation now</span></label>
      {error && <p className="admin-alert error" role="alert">{error}</p>}
      <div className="admin-actions"><Button type="submit" disabled={busy}>{busy ? 'Inviting…' : parsed.emails.length > 1 ? `Invite ${parsed.emails.length} people` : 'Invite'}</Button></div>
    </form>}
  </AdminDialog>
}
