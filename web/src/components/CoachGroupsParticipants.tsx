import { useCallback, useEffect, useEffectEvent, useLayoutEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import { createAdminCohort, createAdminUser, fetchAdminCohorts, fetchAdminUsers, ApiRequestError, removeCoachGroupParticipant, resendAdminUserInvitation, updateAdminCohort } from '../api'
import type { AdminCohort, AdminCohortInput, AdminCohortStatus, AdminUser, AdminUserMutationResponse, CurrentUser } from '../api'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'
import { Button } from './Button'
import './CoachGroupsParticipants.css'
import { confirmDiscard } from '../lib/confirmAction'

type GroupDraft = { name: string; status: AdminCohortStatus; starts_on: string; ends_on: string; notes: string }
const draftFor = (group: AdminCohort): GroupDraft => ({ name: group.name, status: group.status, starts_on: group.starts_on ?? '', ends_on: group.ends_on ?? '', notes: group.notes })
const messageFor = (error: unknown) => error instanceof Error ? error.message : 'This change could not be completed. Please try again.'

function invitationNotice(result: AdminUserMutationResponse): string {
  if (result.invitation_sent === true && result.invitation_status === 'sent') return 'Participant added. Invitation email sent.'
  if (result.invitation_status === 'failed') return 'Participant added. The invitation email did not send. Open Participant access beside their name to resend it.'
  return 'Participant added. No invitation email was sent.'
}

type Props = {
  currentUser: CurrentUser
  workspaceId: number | null
  mutationLifecycle: CoachWorkspaceMutationLifecycle
  onDirtyChange: (dirty: boolean) => void
  onGroupsChanged?: () => void
  onContextNotice?: (notice: string) => void
  selectedCohortId?: number | null
  onSelectedCohortIdChange?: (id: number | null) => void
}

export function CoachGroupsParticipants(props: Props) {
  const membership = props.currentUser.coach_workspaces?.find((workspace) => workspace.id === props.workspaceId)
  const allowed = props.workspaceId !== null && (props.currentUser.is_admin || membership?.membership_role === 'owner')
  return <GroupsPanel key={`${props.workspaceId ?? 'platform'}:${allowed}`} {...props} allowed={allowed} />
}

function GroupsPanel({ workspaceId, mutationLifecycle, onDirtyChange, onGroupsChanged, onContextNotice, selectedCohortId, onSelectedCohortIdChange, allowed }: Props & { allowed: boolean }) {
  const [groups, setGroups] = useState<AdminCohort[]>([])
  const [users, setUsers] = useState<AdminUser[]>([])
  const [selectedId, setSelectedId] = useState<number | null>(null)
  const [previousCohortId, setPreviousCohortId] = useState(selectedCohortId)
  const [draft, setDraft] = useState<GroupDraft | null>(null)
  const [createOpen, setCreateOpen] = useState(false)
  const [newName, setNewName] = useState('')
  const [email, setEmail] = useState('')
  const [inviteOpen, setInviteOpen] = useState(false)
  const [emailList, setEmailList] = useState('')
  const [reviewEmails, setReviewEmails] = useState<string[] | null>(null)
  const [listProblems, setListProblems] = useState<string[]>([])
  const [sendEmail, setSendEmail] = useState(true)
  const [search, setSearch] = useState('')
  const [rosterPage, setRosterPage] = useState(0)
  const [removingId, setRemovingId] = useState<number | null>(null)
  const [loading, setLoading] = useState(allowed)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const generation = useRef(0)
  const panel = useRef<HTMLElement>(null)
  const invitation = useRef<HTMLDetailsElement>(null)
  const selected = groups.find((group) => group.id === selectedId) ?? null
  const groupDirty = !!selected && !!draft && JSON.stringify(draftFor(selected)) !== JSON.stringify(draft)
  const dirty = groupDirty || newName.trim().length > 0 || email.trim().length > 0 || emailList.trim().length > 0
  // Publish the saved baseline before controls become interactive again. A
  // passive effect can leave the parent guarding navigation with stale dirt.
  useLayoutEffect(() => { onDirtyChange(dirty) }, [dirty, onDirtyChange])

  const load = useCallback(async (preferredId?: number | null) => {
    const [nextGroups, nextUsers] = await Promise.all([fetchAdminCohorts(), fetchAdminUsers()])
    return { nextGroups, nextUsers, nextId: nextGroups.some((group) => group.id === preferredId) ? preferredId! : nextGroups[0]?.id ?? null }
  }, [])

  const acceptLoadedGroups = useEffectEvent(({ nextGroups, nextUsers, nextId: fallbackId }: Awaited<ReturnType<typeof load>>) => {
    const nextId = nextGroups.some((group) => group.id === selectedCohortId) ? selectedCohortId! : fallbackId
    if (nextGroups.length === 0) setCreateOpen(true)
    setGroups(nextGroups); setUsers(nextUsers); setSelectedId(nextId); onSelectedCohortIdChange?.(nextId)
    setDraft(nextGroups.find((group) => group.id === nextId) ? draftFor(nextGroups.find((group) => group.id === nextId)!) : null)
  })

  useEffect(() => {
    const request = ++generation.current
    if (!allowed) return
    void load().then((data) => {
      if (request !== generation.current) return
      acceptLoadedGroups(data)
    }).catch((caught) => { if (request === generation.current) setError(messageFor(caught)) })
      .finally(() => { if (request === generation.current) setLoading(false) })
    return () => { generation.current += 1 }
  }, [allowed, load, workspaceId])

  // Cohort selection and its controlled echo use the already loaded roster.
  // Adjust before rendering so a newly selected group never shows the old draft.
  if (selectedCohortId !== previousCohortId) {
    setPreviousCohortId(selectedCohortId)
    const group = groups.find((item) => item.id === selectedCohortId)
    if (group && group.id !== selectedId) {
      setSelectedId(group.id); setDraft(draftFor(group)); setRosterPage(0); setSearch(''); setEmail(''); setEmailList(''); setReviewEmails(null); setRemovingId(null); setError(null); setNotice(null); setNewName(''); setCreateOpen(false)
    }
  }

  const groupParticipants = useMemo(() => users.filter((user) => user.is_participant && user.cohorts.some((membership) => membership.cohort.id === selectedId)), [selectedId, users])
  const participants = useMemo(() => groupParticipants.filter((user) => `${user.full_name} ${user.email}`.toLowerCase().includes(search.trim().toLowerCase())), [search, groupParticipants])
  const rosterPages = Math.ceil(participants.length / 10)
  const currentRosterPage = Math.min(rosterPage, Math.max(0, rosterPages - 1))
  const visibleParticipants = participants.slice(currentRosterPage * 10, (currentRosterPage + 1) * 10)
  const disabled = busy || loading || mutationLifecycle.pending

  useLayoutEffect(() => {
    const access = panel.current?.closest<HTMLDetailsElement>('.coach-access-disclosure')
    if (!access) return
    function focusInvitation() {
      if (access?.dataset.inviteRequested !== 'true' || !invitation.current) return
      invitation.current.open = true
      const input = invitation.current.querySelector<HTMLInputElement>('input[type="email"]')
      if (!input || input.disabled) return
      delete access.dataset.inviteRequested
      input.focus({ preventScroll: true })
      invitation.current.scrollIntoView({ block: 'start' })
    }
    focusInvitation()
    access.addEventListener('coach-invite-requested', focusInvitation)
    return () => access.removeEventListener('coach-invite-requested', focusInvitation)
  }, [loading, selectedId, disabled])

  function changeRosterPage(nextPage: number) {
    if (disabled) return
    setRosterPage(nextPage)
    setRemovingId(null)
  }

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
      const contextChanging = selectedCohortId !== undefined && result.preferredId && result.preferredId !== selectedCohortId && onContextNotice
      setNotice(contextChanging ? null : result.notice)
      onContextNotice?.(contextChanging ? result.notice : '')
      const data = await load(result.preferredId ?? selectedId)
      if (!mutationLifecycle.isCurrent(ticket) || request !== generation.current) return
      if (data.nextId !== selectedId) { setRosterPage(0); setSearch(''); setRemovingId(null) }
      setGroups(data.nextGroups); setUsers(data.nextUsers); setSelectedId(data.nextId); onSelectedCohortIdChange?.(data.nextId)
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

  async function chooseGroup(nextId: number) {
    if (disabled || nextId === selectedId) return
    if ((groupDirty || email.trim() || emailList.trim()) && !(await confirmDiscard('Discard unsaved group or invitation changes?'))) return
    const group = groups.find((item) => item.id === nextId)
    setRosterPage(0); setSearch(''); setSelectedId(nextId); onSelectedCohortIdChange?.(nextId); setDraft(group ? draftFor(group) : null); setEmail(''); setEmailList(''); setReviewEmails(null); setRemovingId(null); setError(null); setNotice(null)
  }
  function saveGroup(event: FormEvent) {
    event.preventDefault()
    if (!selected || !draft) return
    const values: AdminCohortInput = { ...draft, name: draft.name.trim(), expected_updated_at: selected.updated_at }
    void mutate(async () => {
      const updated = await updateAdminCohort(selected.id, values)
      return { notice: 'Group saved. Review participant changes in Go live.', preferredId: updated.id, updatedGroup: updated }
    })
  }
  function createGroup(event: FormEvent) {
    event.preventDefault()
    void mutate(async () => { const group = await createAdminCohort({ name: newName.trim(), status: 'enrolling' }); return { notice: 'Group created. Add participants, then prepare and go live.', preferredId: group.id } }, () => { setNewName(''); setCreateOpen(false) })
  }
  function inviteParticipant(event: FormEvent) {
    event.preventDefault()
    if (!selected) return
    void mutate(async () => {
      const result = await createAdminUser({ email: email.trim(), role: 'participant', cohort_id: selected.id, send_invitation_email: sendEmail })
      window.dispatchEvent(new CustomEvent('coach-roster-changed', { detail: selected.id }))
      return { notice: invitationNotice(result) }
    }, () => { setEmail(''); setInviteOpen(true) })
  }

  function reviewList() {
    const entries = emailList.split(/[,;\n]+/).flatMap(line => line.match(/[^<>]*<[^<>]*>|[^<>]+|[<>]/g) ?? []).flatMap(line => line.includes('<') || line.includes('>') || (line.match(/@/g)?.length === 1) ? [line.trim()] : line.trim().split(/\s+/)).filter(Boolean)
    const emails: string[] = []
    const problems: string[] = []
    const valid = /^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*@(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/
    for (const entry of entries) {
      const named = entry.match(/^[^<>]+<([^<>]+)>$/)
      const address = (named?.[1] ?? entry).trim().toLowerCase()
      if (address.length > 254 || !valid.test(address)) problems.push(`${entry}: Enter a complete email address without spaces or extra punctuation.`)
      else if (!emails.includes(address)) emails.push(address)
    }
    if (emails.length > 100) { setError('Review up to 100 email addresses at a time.'); return }
    setListProblems(problems); setError(null); setReviewEmails(emails.length ? emails : null)
  }
  async function inviteList() {
    if (!selected || !reviewEmails || disabled) return
    const remaining: string[] = []
    const problems: string[] = []
    const inviteGeneration = generation.current
    let added = 0
    let existing = 0
    let unsent = 0
    await mutate(async () => {
      for (const [index, address] of reviewEmails.entries()) {
        if (inviteGeneration !== generation.current) break
        if (groupParticipants.some(user => user.email.toLowerCase() === address)) { existing += 1; continue }
        try {
          const result = await createAdminUser({ email: address, role: 'participant', cohort_id: selected.id, send_invitation_email: sendEmail })
          added += 1
          if (sendEmail && result.invitation_status === 'failed') unsent += 1
        } catch (caught) {
          if (caught instanceof ApiRequestError && [400, 403, 409, 422].includes(caught.status)) {
            problems.push(`${address}: ${messageFor(caught)}`)
            continue
          }
          remaining.push(...reviewEmails.slice(index))
          problems.push(`${address}: ${messageFor(caught)} Remaining addresses are ready to retry.`)
          break
        }
      }
      return { notice: `${added} ${added === 1 ? 'person added' : 'people added'}.${existing ? ` ${existing} already in this group.` : ''}${unsent ? ` ${unsent} invitation ${unsent === 1 ? 'email did' : 'emails did'} not send. Open Participant access to resend.` : ''}${remaining.length ? ` ${remaining.length} still to add. Review the remaining list and try again.` : ''}` }
    }, () => {
      setListProblems(problems); setEmailList(remaining.join('\n')); setReviewEmails(remaining.length ? remaining : null); setInviteOpen(true)
      window.dispatchEvent(new CustomEvent('coach-roster-changed', { detail: selected.id }))
    })
  }

  if (!workspaceId) return <section className="coach-groups"><h2>Groups & participants</h2><p>Choose a program to manage its groups and participants.</p></section>
  if (!allowed) return <section className="coach-groups"><h2>Groups & participants</h2><p>Ask a program owner to create groups and manage participant invitations. Your collaborator role does not include roster access.</p></section>
  return <section ref={panel} className="coach-groups" aria-label="Groups and participants">
    <header className="coach-groups-header"><div><h2>Groups & participants</h2><p>Organize your program into groups and invite participants by email.</p></div><div className="coach-groups-actions"><Button variant="secondary" disabled={disabled} onClick={async () => {
      if (dirty && !(await confirmDiscard('Discard unsaved changes and reload groups?'))) return
      void mutate(async () => ({ notice: 'Groups and participants reloaded.' }), () => { setEmail(''); setNewName(''); setRemovingId(null) })
    }}>Reload groups</Button><Button variant="secondary" disabled={disabled} onClick={async () => {
      if (createOpen && newName.trim() && !(await confirmDiscard('Discard the new group name?', { title: 'Discard this group name?' }))) return
      setNewName(''); setCreateOpen((open) => !open)
    }}>{createOpen ? 'Close new group' : 'New group'}</Button></div></header>
    {error && <div className="coach-groups-error" role="alert">{error}</div>}
    {listProblems.length > 0 && <div role="alert"><p>These addresses were not added:</p><ul>{listProblems.map(problem => <li key={problem}>{problem}</li>)}</ul></div>}
    {notice && <div className="coach-groups-notice" role="status">{notice}</div>}
    {loading && <p role="status">Loading groups and participants…</p>}
    {createOpen && <form className="coach-groups-card" onSubmit={createGroup}><h3>Create a group</h3><label>Group name<input required maxLength={120} value={newName} disabled={disabled} onChange={(event) => setNewName(event.target.value)} /></label><p>New groups start as Enrolling. Review the assistant, then go live when you are ready.</p><Button type="submit" disabled={disabled || !newName.trim() || groupDirty || !!email.trim()}>Create group</Button>{(groupDirty || email.trim()) && <p>Save or discard the current group or invitation changes first.</p>}</form>}
    {!loading && groups.length === 0 && <p>Create your first group to invite participants.</p>}
    {selectedCohortId === undefined && !!groups.length && <label className="coach-group-picker">Group<select disabled={disabled} value={selectedId ?? ''} onChange={(event) => chooseGroup(Number(event.target.value))}>{groups.map((group) => <option key={group.id} value={group.id}>{group.name} · {group.participant_count} participants</option>)}</select></label>}
    {selected && draft && <>
      <details className="coach-group-settings"><summary>Group details & dates</summary><form className="coach-groups-card" onSubmit={saveGroup}><h3>Group details</h3><div className="coach-groups-grid"><label>Group name<input required maxLength={120} value={draft.name} disabled={disabled} onChange={(event) => setDraft({ ...draft, name: event.target.value })} /></label><label>Group status<select value={draft.status} disabled={disabled} onChange={(event) => setDraft({ ...draft, status: event.target.value as AdminCohortStatus })}><option value="draft">Draft</option><option value="enrolling">Enrolling</option><option value="active">Active</option><option value="completed">Completed</option><option value="archived">Archived</option></select></label><label>Start date<input type="date" value={draft.starts_on} disabled={disabled} onChange={(event) => setDraft({ ...draft, starts_on: event.target.value })} /></label><label>End date (optional)<input type="date" value={draft.ends_on} min={draft.starts_on || undefined} disabled={disabled} onChange={(event) => setDraft({ ...draft, ends_on: event.target.value })} /></label></div><label>Group notes (optional)<textarea rows={3} maxLength={2000} value={draft.notes} disabled={disabled} onChange={(event) => setDraft({ ...draft, notes: event.target.value })} /></label><p>A savings challenge needs a start date before it can open. Each participant gets 90 days; the group end date is optional. Status organizes the group. It does not publish or launch an assistant, tools, or branding. Completed and archived groups cannot have an open rollout.</p><div className="coach-groups-actions"><Button type="submit" disabled={disabled || !groupDirty || !draft.name.trim()}>Save group</Button><Button variant="secondary" disabled={disabled || !groupDirty} onClick={() => setDraft(draftFor(selected))}>Discard changes</Button></div></form></details>
      <details ref={invitation} className="coach-group-settings" open={inviteOpen || groupParticipants.length === 0 || undefined} onToggle={event => setInviteOpen(event.currentTarget.open)}><summary>Add a participant</summary><form className="coach-groups-card" onSubmit={inviteParticipant}><h3>Add a participant</h3><label>Participant email<input type="email" required maxLength={254} autoComplete="email" value={email} disabled={disabled} onChange={(event) => setEmail(event.target.value)} /></label><label className="coach-groups-check"><input type="checkbox" checked={sendEmail} disabled={disabled} onChange={(event) => setSendEmail(event.target.checked)} />Send an invitation email when eligible</label><p>Existing participants can join another group if its assistant and participant tools are compatible. Their account and other groups stay unchanged. Shared or accepted accounts may be added without another email.</p><Button type="submit" disabled={disabled || !email.trim() || groupDirty || !!newName.trim()}>Add to {selected.name}</Button>{(groupDirty || newName.trim()) && <p>Save or discard group changes first.</p>}</form><div className="coach-groups-card"><h3>Add several people</h3><label>Paste email addresses<textarea rows={5} maxLength={25500} value={emailList} disabled={disabled} onChange={event => { setEmailList(event.target.value); setReviewEmails(null) }} /></label><p>Separate addresses with commas, spaces or new lines. You’ll review the list before anyone is added.</p>{reviewEmails ? <><h4>Review {reviewEmails.length} {reviewEmails.length === 1 ? 'person' : 'people'} for {selected.name}</h4><ul className="coach-invitation-review" tabIndex={0} aria-label="Email addresses to add">{reviewEmails.map(address => <li key={address}>{address}</li>)}</ul><p>{sendEmail ? 'An invitation email will be requested for each eligible person.' : 'No invitation emails will be sent.'}</p><Button disabled={disabled || groupDirty || !!newName.trim() || !!email.trim()} onClick={() => void inviteList()}>Add {reviewEmails.length === 1 ? 'this person' : `these ${reviewEmails.length} people`}</Button><Button variant="secondary" disabled={disabled} onClick={() => setReviewEmails(null)}>Change the list</Button></> : <Button variant="secondary" disabled={disabled || !emailList.trim() || groupDirty || !!newName.trim() || !!email.trim()} onClick={reviewList}>Review email list</Button>}</div></details>
      <section className="coach-groups-card"><h3>Participants in {selected.name}</h3><label>Find a participant<input type="search" value={search} disabled={disabled} onChange={(event) => { setSearch(event.target.value); setRosterPage(0); setRemovingId(null) }} /></label><p>Invitation pending describes account access, not email delivery. Historical email delivery details are private to platform administrators.</p>
        {!participants.length && <p>{search ? 'No participants match your search.' : 'No participants in this group yet.'}</p>}
        {!!participants.length && <p className="coach-roster-count">Showing {currentRosterPage * 10 + 1}–{Math.min((currentRosterPage + 1) * 10, participants.length)} of {participants.length} {search.trim() ? 'matching participants' : 'participants'}.</p>}
        <ul className="coach-participants-list">{visibleParticipants.map((user) => { const membership = user.cohorts.find((item) => item.cohort.id === selected.id)!; return <li key={user.id}><div><strong>{user.full_name || user.email}</strong><span>{user.email}</span><span>{user.invitation_status === 'accepted' ? 'Joined' : user.invitation_status === 'revoked' ? 'Account access revoked' : 'Invitation pending'} · Optional household setup: {user.workspace.setup_complete ? 'complete' : 'not complete'}</span></div><details className="coach-participant-access"><summary>Participant access</summary><div className="coach-groups-actions">{user.can_resend_invitation && <Button variant="secondary" disabled={disabled || dirty} onClick={() => void mutate(async () => { const result = await resendAdminUserInvitation(user.id); return { notice: result.invitation_sent ? 'Invitation email sent.' : 'The invitation email did not send. Try Resend invitation again in a minute.' } })}>Resend invitation</Button>}<Button variant="secondary" disabled={disabled || dirty} onClick={() => setRemovingId(user.id)}>{user.invitation_status === 'pending' ? 'Cancel enrollment' : 'Remove from group'}</Button></div>{removingId === user.id && <div className="coach-participant-confirm"><p>Remove {user.full_name || user.email} from {selected.name}? They will lose this group’s experience. Their account and other group memberships stay available.</p><div className="coach-groups-actions"><Button disabled={disabled} onClick={() => void mutate(async () => { await removeCoachGroupParticipant(selected.id, user.id, membership.id); return { notice: 'Enrollment removed from this group. The participant’s account remains available.' } }, () => setRemovingId(null))}>Confirm removal</Button><Button variant="secondary" disabled={disabled} onClick={() => setRemovingId(null)}>Keep participant</Button></div></div>}</details></li> })}</ul>
        {rosterPages > 1 && <nav className="coach-roster-pages" aria-label="Participant roster pages"><Button variant="secondary" disabled={disabled || currentRosterPage === 0} onClick={() => changeRosterPage(currentRosterPage - 1)}>Previous participants</Button><span>Page {currentRosterPage + 1} of {rosterPages}</span><Button variant="secondary" disabled={disabled || currentRosterPage + 1 >= rosterPages} onClick={() => changeRosterPage(currentRosterPage + 1)}>Next participants</Button></nav>}
      </section>
    </>}
  </section>
}
