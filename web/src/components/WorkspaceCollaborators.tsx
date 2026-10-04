import { useEffect, useId, useRef, useState, type FormEvent } from 'react'
import {
  addWorkspaceCollaborator, changeWorkspaceCollaborator, fetchWorkspaceCollaborators, removeWorkspaceCollaborator,
  sendWorkspaceCollaboratorEmail, ApiRequestError, type CollaboratorDelivery, type WorkspaceCollaborator,
  type WorkspaceCollaboratorRole, type WorkspaceCollaboratorsPayload,
} from '../api'
import { Button } from './Button'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'
import './WorkspaceCollaborators.css'

const roles: WorkspaceCollaboratorRole[] = ['viewer', 'editor', 'reviewer', 'owner']
const roleDescriptions: Record<WorkspaceCollaboratorRole, string> = {
  viewer: 'View coaching configuration.', editor: 'Prepare drafts and previews.',
  reviewer: 'Review, publish, assign, and release approved configuration.', owner: 'All coach tools, program settings, and team access.',
}

type Props = {
  workspaceId: number
  mutationLifecycle: CoachWorkspaceMutationLifecycle
  onDirtyChange?: (dirty: boolean) => void
}

export function WorkspaceCollaborators(props: Props) {
  return <CollaboratorPanel key={props.workspaceId} {...props} />
}

function CollaboratorPanel({ workspaceId, mutationLifecycle, onDirtyChange }: Props) {
  const [data, setData] = useState<WorkspaceCollaboratorsPayload | null>(null)
  const [loading, setLoading] = useState(true)
  const [unavailable, setUnavailable] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [email, setEmail] = useState('')
  const [role, setRole] = useState<WorkspaceCollaboratorRole>('viewer')
  const [sendEmail, setSendEmail] = useState(true)
  const [draftRoles, setDraftRoles] = useState<Record<number, WorkspaceCollaboratorRole>>({})
  const [pending, setPending] = useState<string | null>(null)
  const [attempt, setAttempt] = useState(0)
  const mounted = useRef(true)
  const nextOperation = useRef(0)
  const pendingOperation = useRef<number | null>(null)
  const roleHelpId = useId()
  const dirty = Boolean(email.trim()) || Boolean(data?.members.some((member) => draftRoles[member.id] && draftRoles[member.id] !== member.role))

  useEffect(() => {
    onDirtyChange?.(dirty)
  }, [dirty, onDirtyChange])

  useEffect(() => {
    mounted.current = true
    const controller = new AbortController()
    void fetchWorkspaceCollaborators(workspaceId, controller.signal).then((response) => {
      if (controller.signal.aborted) return
      if (response.workspace_id !== workspaceId) throw new Error('Team data returned the wrong program. Reload and try again.')
      setData(response)
      setUnavailable(false)
      setError(null)
    }).catch((caught: unknown) => {
      if (controller.signal.aborted) return
      if (caught instanceof ApiRequestError && caught.status === 404) {
        setData(null)
        setUnavailable(true)
      }
      else setError(message(caught, 'Your team could not be loaded.'))
    }).finally(() => {
      if (!controller.signal.aborted) setLoading(false)
    })
    return () => {
      mounted.current = false
      controller.abort()
    }
  }, [attempt, workspaceId])

  async function mutate(key: string, operation: (isCurrent: () => boolean) => Promise<void>) {
    if (pendingOperation.current !== null || !data?.permissions.manage) return
    const operationId = ++nextOperation.current
    pendingOperation.current = operationId
    const ticket = mutationLifecycle.begin()
    const isCurrent = () => mounted.current && pendingOperation.current === operationId && mutationLifecycle.isCurrent(ticket)
    setPending(key)
    setError(null)
    setNotice(null)
    try {
      await operation(isCurrent)
    } catch (caught) {
      if (isCurrent()) setError(message(caught, 'That team change could not be confirmed.'))
    } finally {
      if (pendingOperation.current === operationId) {
        pendingOperation.current = null
        if (mounted.current) setPending(null)
      }
      mutationLifecycle.finish(ticket)
    }
  }

  function replaceMember(member: WorkspaceCollaborator) {
    if (!mounted.current) return
    setData((current) => current ? { ...current, members: current.members.some((item) => item.id === member.id)
      ? current.members.map((item) => item.id === member.id ? member : item) : [...current.members, member] } : current)
    setDraftRoles((current) => ({ ...current, [member.id]: member.role }))
  }

  function add(event: FormEvent) {
    event.preventDefault()
    void mutate('add', async (isCurrent) => {
      const result = await addWorkspaceCollaborator(workspaceId, email.trim(), role, sendEmail)
      if (!isCurrent()) return
      replaceMember(result.member)
      setEmail('')
      setNotice(result.added ? `Workspace access saved for ${result.member.email}. ${deliveryNotice(result.delivery)}` : 'This person already has the same workspace access. No new email was sent.')
    })
  }

  function saveRole(member: WorkspaceCollaborator) {
    const nextRole = draftRoles[member.id]
    if (!nextRole || nextRole === member.role) return
    if (!window.confirm(`Change ${member.email} from ${member.role} to ${nextRole}? ${roleDescriptions[nextRole]}`)) return
    void mutate(`role:${member.id}`, async (isCurrent) => {
      const result = await changeWorkspaceCollaborator(workspaceId, member, nextRole)
      if (!isCurrent()) return
      replaceMember(result.member)
      setNotice(`Saved ${result.member.email} as ${result.member.role}.`)
    })
  }

  function remove(member: WorkspaceCollaborator) {
    if (!window.confirm(`Remove ${member.email} from this coaching workspace and its staff cohort assignments? Their participant enrollments and access to other programs will stay intact.${member.platform_admin ? ' Platform administrators retain platform access.' : ''}`)) return
    void mutate(`remove:${member.id}`, async (isCurrent) => {
      const result = await removeWorkspaceCollaborator(workspaceId, member)
      if (!isCurrent()) return
      setData((current) => current ? { ...current, members: current.members.filter((item) => item.id !== member.id) } : current)
      setNotice(`Workspace membership removed.${result.platform_admin ? ' This platform administrator retains platform access.' : ''}`)
    })
  }

  function sendAccessEmail(member: WorkspaceCollaborator) {
    void mutate(`email:${member.id}`, async (isCurrent) => {
      const result = await sendWorkspaceCollaboratorEmail(workspaceId, member.id)
      if (isCurrent()) setNotice(deliveryNotice(result.delivery))
    })
  }

  function refresh() {
    if (dirty && !window.confirm('Discard unsaved team changes and load the current access list?')) return
    setEmail('')
    setDraftRoles({})
    setData(null)
    setLoading(true)
    setAttempt((value) => value + 1)
  }

  const activeOwnerCount = data?.members.filter((member) => member.role === 'owner' && member.status === 'accepted').length ?? 0
  return <article className="panel workspace-collaborators" aria-busy={Boolean(pending) || loading}>
    <header><div><p className="eyebrow">Your team</p><h3>Give collaborators the access they need.</h3><p>Team access controls coaching configuration. It does not share participant financial records.</p></div></header>
    {loading && <p role="status">Loading team access…</p>}
    {unavailable && <p>Workspace owners and platform administrators manage collaborators.</p>}
    {error && <p className="coach-studio-alert is-error" role="alert">{error}</p>}
    {notice && <p className="coach-studio-alert is-success" role="status">{notice}</p>}
    {data?.permissions.manage && <>
      <form className="workspace-collaborator-form" onSubmit={add}>
        <label><span>Collaborator email</span><input type="email" autoComplete="email" maxLength={254} required value={email} disabled={Boolean(pending)} onChange={(event) => setEmail(event.target.value)} /></label>
        <label><span>Access role</span><select aria-label="Access role" aria-describedby={roleHelpId} value={role} disabled={Boolean(pending)} onChange={(event) => setRole(event.target.value as WorkspaceCollaboratorRole)}>{roles.map((item) => <option key={item} value={item}>{item[0].toUpperCase() + item.slice(1)}</option>)}</select><small id={roleHelpId}>{roleDescriptions[role]}</small></label>
        <label className="workspace-collaborator-email"><input type="checkbox" checked={sendEmail} disabled={Boolean(pending)} onChange={(event) => setSendEmail(event.target.checked)} /><span>Send an access email</span></label>
        <Button type="submit" disabled={Boolean(pending) || !email.trim()}>{pending === 'add' ? 'Saving access' : 'Add collaborator'}</Button>
      </form>
      <p className="workspace-collaborator-help">New coaches sign in with their invited email. Existing coaches keep their account and other programs. An invited owner must sign in before they can replace your last active owner.</p>
      {data.sign_in_url && <p className="workspace-collaborator-help">Sign-in link to share: <a href={data.sign_in_url} target="_blank" rel="noreferrer">{data.sign_in_url}</a></p>}
      <div className="workspace-collaborator-list">{data.members.map((member) => {
        const protectedOwner = member.role === 'owner' && (member.is_self || (member.status === 'accepted' && activeOwnerCount <= 1))
        return <section className="workspace-collaborator" key={member.id} aria-label={`${member.email} team access`}>
          <div><strong>{member.full_name}{member.is_self ? ' · You' : ''}</strong><span>{member.email}</span><small>{member.status === 'pending' ? 'Invited · awaiting sign-in' : member.status === 'revoked' ? 'Account revoked · contact platform administrator' : 'Active'}{member.platform_admin ? ' · Platform administrator' : ''}</small></div>
          <label><span>Role for {member.email}</span><select value={draftRoles[member.id] ?? member.role} disabled={Boolean(pending) || protectedOwner} onChange={(event) => setDraftRoles((current) => ({ ...current, [member.id]: event.target.value as WorkspaceCollaboratorRole }))}>{roles.map((item) => <option key={item} value={item}>{item[0].toUpperCase() + item.slice(1)}</option>)}</select></label>
          <div className="workspace-collaborator-actions">
            <Button size="compact" disabled={Boolean(pending) || protectedOwner || !draftRoles[member.id] || draftRoles[member.id] === member.role} onClick={() => saveRole(member)}>Save role</Button>
            <Button size="compact" variant="secondary" disabled={Boolean(pending) || member.status === 'revoked'} onClick={() => sendAccessEmail(member)}>Send access email</Button>
            <Button size="compact" variant="danger" disabled={Boolean(pending) || protectedOwner || member.is_self} onClick={() => remove(member)}>Remove</Button>
          </div>
          {protectedOwner && <small>Your own owner access and the last active owner are protected.</small>}
        </section>
      })}</div>
    </>}
    {!unavailable && <Button variant="ghost" size="compact" disabled={Boolean(pending) || loading} onClick={refresh}>Refresh team</Button>}
  </article>
}

function deliveryNotice(delivery: CollaboratorDelivery | null) {
  if (delivery?.status === 'sent') return 'The email provider accepted the access email.'
  if (delivery?.status === 'skipped') return 'No email was sent. Share the sign-in link with them.'
  return 'Access was saved, but the email could not be confirmed. Share the sign-in link or try Send access email.'
}

function message(error: unknown, fallback: string) {
  return error instanceof Error ? error.message : fallback
}
