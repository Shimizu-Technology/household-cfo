import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import { createAdminCohort, createAdminUser, fetchAdminCohorts, fetchAdminUsers, removeCoachGroupParticipant, resendAdminUserInvitation, updateAdminCohort } from '../api'
import type { AdminCohort, AdminCohortInput, AdminCohortStatus, AdminUser, AdminUserMutationResponse, CurrentUser } from '../api'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'
import { Button } from './Button'
import './CoachGroupsParticipants.css'

type GroupDraft = { name: string; status: AdminCohortStatus; starts_on: string; ends_on: string; notes: string }
const draftFor = (group: AdminCohort): GroupDraft => ({ name: group.name, status: group.status, starts_on: group.starts_on ?? '', ends_on: group.ends_on ?? '', notes: group.notes })
const messageFor = (error: unknown) => error instanceof Error ? error.message : 'This change could not be completed. Please try again.'

function invitationNotice(result: AdminUserMutationResponse): string {
  if (result.invitation_sent === true && result.invitation_status === 'sent') return 'Participant added. Invitation email sent.'
  if (result.invitation_status === 'failed') return `Participant added, but the invitation email failed. ${result.invitation_error ?? 'Try resending it.'}`
  return result.invitation_error || 'Participant added. No invitation email was sent.'
}

type Props = {
  currentUser: CurrentUser
  workspaceId: number | null
  mutationLifecycle: CoachWorkspaceMutationLifecycle
  onDirtyChange: (dirty: boolean) => void
  onGroupsChanged?: () => void
}

export function CoachGroupsParticipants(props: Props) {
  const membership = props.currentUser.coach_workspaces?.find((workspace) => workspace.id === props.workspaceId)
  const allowed = props.workspaceId !== null && (props.currentUser.is_admin || membership?.membership_role === 'owner')
  return <GroupsPanel key={`${props.workspaceId ?? 'platform'}:${allowed}`} {...props} allowed={allowed} />
}

function GroupsPanel({ workspaceId, mutationLifecycle, onDirtyChange, onGroupsChanged, allowed }: Props & { allowed: boolean }) {
  const [groups, setGroups] = useState<AdminCohort[]>([])
  const [users, setUsers] = useState<AdminUser[]>([])
  const [selectedId, setSelectedId] = useState<number | null>(null)
  const [draft, setDraft] = useState<GroupDraft | null>(null)
  const [createOpen, setCreateOpen] = useState(false)
  const [newName, setNewName] = useState('')
  const [email, setEmail] = useState('')
  const [sendEmail, setSendEmail] = useState(true)
  const [search, setSearch] = useState('')
  const [removingId, setRemovingId] = useState<number | null>(null)
  const [loading, setLoading] = useState(allowed)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const generation = useRef(0)
  const selected = groups.find((group) => group.id === selectedId) ?? null
  const groupDirty = !!selected && !!draft && JSON.stringify(draftFor(selected)) !== JSON.stringify(draft)
  const dirty = groupDirty || newName.trim().length > 0 || email.trim().length > 0
  useEffect(() => { onDirtyChange(dirty) }, [dirty, onDirtyChange])

  const load = useCallback(async (preferredId?: number | null) => {
    const [nextGroups, nextUsers] = await Promise.all([fetchAdminCohorts(), fetchAdminUsers()])
    return { nextGroups, nextUsers, nextId: nextGroups.some((group) => group.id === preferredId) ? preferredId! : nextGroups[0]?.id ?? null }
  }, [])

  useEffect(() => {
    const request = ++generation.current
    if (!allowed) return
    void load().then(({ nextGroups, nextUsers, nextId }) => {
      if (request !== generation.current) return
      setGroups(nextGroups); setUsers(nextUsers); setSelectedId(nextId)
      setDraft(nextGroups.find((group) => group.id === nextId) ? draftFor(nextGroups.find((group) => group.id === nextId)!) : null)
    }).catch((caught) => { if (request === generation.current) setError(messageFor(caught)) })
      .finally(() => { if (request === generation.current) setLoading(false) })
    return () => { generation.current += 1 }
  }, [allowed, load, workspaceId])

  const participants = useMemo(() => users.filter((user) => user.is_participant && user.cohorts.some((membership) => membership.cohort.id === selectedId))
    .filter((user) => `${user.full_name} ${user.email}`.toLowerCase().includes(search.trim().toLowerCase())), [search, selectedId, users])
  const disabled = busy || loading || mutationLifecycle.pending

  async function mutate(action: () => Promise<{ notice: string; preferredId?: number; updatedGroup?: AdminCohort }>, afterSuccess?: () => void) {
    if (disabled) return
    const ticket = mutationLifecycle.begin()
    const request = generation.current
    setBusy(true); setError(null); setNotice(null)
    try {
      const result = await action()
      if (!mutationLifecycle.isCurrent(ticket) || request !== generation.current) return
      // Commit local success before refresh: a failed roster refresh must not
      // invite the user to repeat an already completed write.
      afterSuccess?.()
      if (result.updatedGroup) {
        const updated = result.updatedGroup
        setGroups((items) => items.map((item) => item.id === updated.id ? updated : item)); setDraft(draftFor(updated))
      }
      setNotice(result.notice)
      const data = await load(result.preferredId ?? selectedId)
      if (!mutationLifecycle.isCurrent(ticket) || request !== generation.current) return
      setGroups(data.nextGroups); setUsers(data.nextUsers); setSelectedId(data.nextId)
      const group = data.nextGroups.find((item) => item.id === data.nextId)
      setDraft(group ? draftFor(group) : null)
      onGroupsChanged?.()
    } catch (caught) {
      if (mutationLifecycle.isCurrent(ticket) && request === generation.current) setError(messageFor(caught))
    } finally {
      if (request === generation.current) setBusy(false)
      mutationLifecycle.finish(ticket)
    }
  }

  function chooseGroup(nextId: number) {
    if (disabled || nextId === selectedId) return
    if ((groupDirty || email.trim()) && !window.confirm('Discard unsaved group or invitation changes?')) return
    const group = groups.find((item) => item.id === nextId)
    setSelectedId(nextId); setDraft(group ? draftFor(group) : null); setEmail(''); setRemovingId(null); setError(null); setNotice(null)
  }
  function saveGroup(event: FormEvent) {
    event.preventDefault()
    if (!selected || !draft) return
    const values: AdminCohortInput = { ...draft, name: draft.name.trim(), expected_updated_at: selected.updated_at }
    void mutate(async () => {
      const updated = await updateAdminCohort(selected.id, values)
      return { notice: 'Group saved. Its participant experience changes only through Launch & rollout.', preferredId: updated.id, updatedGroup: updated }
    })
  }
  function createGroup(event: FormEvent) {
    event.preventDefault()
    void mutate(async () => { const group = await createAdminCohort({ name: newName.trim(), status: 'enrolling' }); return { notice: 'Group created. Add participants, then prepare and launch its experience.', preferredId: group.id } }, () => { setNewName(''); setCreateOpen(false) })
  }
  function inviteParticipant(event: FormEvent) {
    event.preventDefault()
    if (!selected) return
    void mutate(async () => {
      const result = await createAdminUser({ email: email.trim(), role: 'participant', cohort_id: selected.id, send_invitation_email: sendEmail })
      return { notice: invitationNotice(result) }
    }, () => setEmail(''))
  }

  if (!workspaceId) return <section className="coach-groups"><h2>Groups & participants</h2><p>Choose a program to manage its groups and participants.</p></section>
  if (!allowed) return <section className="coach-groups"><h2>Groups & participants</h2><p>Ask a program owner to create groups and manage participant invitations. Your collaborator role does not include roster access.</p></section>
  return <section className="coach-groups" aria-label="Groups and participants">
    <header className="coach-groups-header"><div><h2>Groups & participants</h2><p>Organize your program into groups and invite participants by email.</p></div><div className="coach-groups-actions"><Button variant="secondary" disabled={disabled} onClick={() => {
      if (dirty && !window.confirm('Discard unsaved changes and reload groups?')) return
      void mutate(async () => ({ notice: 'Groups and participants reloaded.' }), () => { setEmail(''); setNewName(''); setRemovingId(null) })
    }}>Reload groups</Button><Button variant="secondary" disabled={disabled} onClick={() => {
      if (createOpen && newName.trim() && !window.confirm('Discard the new group name?')) return
      setNewName(''); setCreateOpen((open) => !open)
    }}>{createOpen ? 'Close new group' : 'New group'}</Button></div></header>
    {error && <div className="coach-groups-error" role="alert">{error}</div>}
    {notice && <div className="coach-groups-notice" role="status">{notice}</div>}
    {loading && <p role="status">Loading groups and participants…</p>}
    {createOpen && <form className="coach-groups-card" onSubmit={createGroup}><h3>Create a group</h3><label>Group name<input required maxLength={120} value={newName} disabled={disabled} onChange={(event) => setNewName(event.target.value)} /></label><p>New groups start as Enrolling. Launch a reviewed participant experience when you are ready.</p><Button type="submit" disabled={disabled || !newName.trim() || groupDirty || !!email.trim()}>Create group</Button>{(groupDirty || email.trim()) && <p>Save or discard the current group or invitation changes first.</p>}</form>}
    {!loading && groups.length === 0 && <p>Create your first group to invite participants.</p>}
    {!!groups.length && <label className="coach-group-picker">Group<select disabled={disabled} value={selectedId ?? ''} onChange={(event) => chooseGroup(Number(event.target.value))}>{groups.map((group) => <option key={group.id} value={group.id}>{group.name} · {group.participant_count} participants</option>)}</select></label>}
    {selected && draft && <>
      <form className="coach-groups-card" onSubmit={saveGroup}><h3>Group details</h3><div className="coach-groups-grid"><label>Group name<input required maxLength={120} value={draft.name} disabled={disabled} onChange={(event) => setDraft({ ...draft, name: event.target.value })} /></label><label>Group status<select value={draft.status} disabled={disabled} onChange={(event) => setDraft({ ...draft, status: event.target.value as AdminCohortStatus })}><option value="draft">Draft</option><option value="enrolling">Enrolling</option><option value="active">Active</option><option value="completed">Completed</option><option value="archived">Archived</option></select></label><label>Start date (optional)<input type="date" value={draft.starts_on} disabled={disabled} onChange={(event) => setDraft({ ...draft, starts_on: event.target.value })} /></label><label>End date (optional)<input type="date" value={draft.ends_on} min={draft.starts_on || undefined} disabled={disabled} onChange={(event) => setDraft({ ...draft, ends_on: event.target.value })} /></label></div><label>Group notes (optional)<textarea rows={3} maxLength={2000} value={draft.notes} disabled={disabled} onChange={(event) => setDraft({ ...draft, notes: event.target.value })} /></label><p>Status organizes the group. It does not publish or launch an assistant, tools, or branding. Completed and archived groups cannot have an open rollout.</p><div className="coach-groups-actions"><Button type="submit" disabled={disabled || !groupDirty || !draft.name.trim()}>Save group</Button><Button variant="secondary" disabled={disabled || !groupDirty} onClick={() => setDraft(draftFor(selected))}>Discard changes</Button></div></form>
      <form className="coach-groups-card" onSubmit={inviteParticipant}><h3>Add a participant</h3><label>Participant email<input type="email" required maxLength={254} autoComplete="email" value={email} disabled={disabled} onChange={(event) => setEmail(event.target.value)} /></label><label className="coach-groups-check"><input type="checkbox" checked={sendEmail} disabled={disabled} onChange={(event) => setSendEmail(event.target.checked)} />Send an invitation email when eligible</label><p>Existing participants can join another group if its assistant is compatible. Their account and other groups stay unchanged. Shared or accepted accounts may be added without another email.</p><Button type="submit" disabled={disabled || !email.trim() || groupDirty || !!newName.trim()}>Add to {selected.name}</Button>{(groupDirty || newName.trim()) && <p>Save or discard group changes first.</p>}</form>
      <section className="coach-groups-card"><h3>Participants in {selected.name}</h3><label>Find a participant<input type="search" value={search} onChange={(event) => setSearch(event.target.value)} /></label><p>Invitation pending describes account access, not email delivery. Historical email delivery details are private to platform administrators.</p>
        {!participants.length && <p>{search ? 'No participants match your search.' : 'No participants in this group yet.'}</p>}
        <ul className="coach-participants-list">{participants.map((user) => { const membership = user.cohorts.find((item) => item.cohort.id === selected.id)!; return <li key={user.id}><div><strong>{user.full_name || user.email}</strong><span>{user.email}</span><span>{user.invitation_status === 'accepted' ? 'Joined' : user.invitation_status === 'revoked' ? 'Account access revoked' : 'Invitation pending'} · {user.workspace.setup_complete ? 'Setup complete' : 'Setup incomplete'}</span></div><div className="coach-groups-actions">{user.can_resend_invitation && <Button variant="secondary" disabled={disabled || dirty} onClick={() => void mutate(async () => { const result = await resendAdminUserInvitation(user.id); return { notice: result.invitation_sent ? 'Invitation email sent.' : `No invitation email was sent. ${result.invitation_error ?? 'Please try again.'}` } })}>Resend invitation</Button>}<Button variant="secondary" disabled={disabled || dirty} onClick={() => setRemovingId(user.id)}>{user.invitation_status === 'pending' ? 'Cancel enrollment' : 'Remove from group'}</Button></div>{removingId === user.id && <div className="coach-participant-confirm"><p>Remove {user.full_name || user.email} from {selected.name}? They will lose this group’s experience. Their account and other group memberships stay available.</p><div className="coach-groups-actions"><Button disabled={disabled} onClick={() => void mutate(async () => { await removeCoachGroupParticipant(selected.id, user.id, membership.id); return { notice: 'Enrollment removed from this group. The participant’s account remains available.' } }, () => setRemovingId(null))}>Confirm removal</Button><Button variant="secondary" disabled={disabled} onClick={() => setRemovingId(null)}>Keep participant</Button></div></div>}</li> })}</ul>
      </section>
    </>}
  </section>
}
