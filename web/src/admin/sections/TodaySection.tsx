import { useEffect, useMemo, useState } from 'react'
import { resendAdminUserInvitation, type AdminCohort, type AdminUser, type CurrentUser } from '../../api'
import { Button } from '../../components/Button'
import { ParticipantHelp } from '../../components/ParticipantHelp'
import { dailyNeed } from '../../lib/coachDailyWords'
import { SetupSupportInbox } from '../../components/SetupSupportInbox'
import { useAuthContext } from '../../contexts/authContextValue'
import { adminPath, navigateTo } from '../../lib/appRoutes'
import { coachChallengeApi, type CoachDailyPage, type CoachDailyPerson } from '../../lib/coachChallengeApi'
import { AdminDialog } from '../AdminDialog'
import { groupLine, inviteStateOf, shortDay } from '../adminWords'
import { joinedCount, useAdminRoster } from '../useAdminRoster'
import { InvitePeople } from './InvitePeople'
import './sections.css'

const FOLLOW_UPS = 5
type Need = { group: AdminCohort; person: CoachDailyPerson }
type Loaded = { page: CoachDailyPage | null }

// "Who needs me today?" Help first, then invitations that went nowhere, then each group at a glance.
export function TodaySection({ currentUser }: { currentUser: CurrentUser }) {
  const { activeCoachWorkspaceId } = useAuthContext()
  const { groups, people, loading, error, reload } = useAdminRoster()
  const [daily, setDaily] = useState<Record<number, Loaded>>({})
  const [open, setOpen] = useState<Need | null>(null)
  const [inviting, setInviting] = useState(false)
  const [resending, setResending] = useState<number | null>(null)
  const [note, setNote] = useState<string | null>(null)
  const live = useMemo(() => groups.filter(group => group.status !== 'archived' && group.status !== 'completed'), [groups])

  useEffect(() => {
    const controller = new AbortController()
    for (const group of live) {
      coachChallengeApi.daily(group.id, '', 'needs_help', 0, controller.signal)
        .then(page => { if (!controller.signal.aborted && page.cohort_id === group.id) setDaily(current => ({ ...current, [group.id]: { page } })) })
        // A group whose people list this person may not read simply has no help list here.
        .catch(() => { if (!controller.signal.aborted) setDaily(current => ({ ...current, [group.id]: { page: null } })) })
    }
    return () => controller.abort()
  }, [live])

  const needs: Need[] = live.flatMap(group => (daily[group.id]?.page?.records ?? []).filter(person => person.needs_help).map(person => ({ group, person })))
  const checking = live.some(group => !daily[group.id])
  const unreadable = live.filter(group => daily[group.id] && daily[group.id].page === null)
  const followUps = people.filter(person => person.role === 'participant' && ['invited', 'bounced'].includes(inviteStateOf(person)))
    .sort((a, b) => Number(inviteStateOf(b) === 'bounced') - Number(inviteStateOf(a) === 'bounced'))

  async function resend(person: AdminUser) {
    if (resending !== null) return
    setResending(person.id); setNote(null)
    try { const response = await resendAdminUserInvitation(person.id); setNote(response.invitation_sent ? `Invitation sent again to ${person.email}.` : `The email to ${person.email} still didn’t send.`); await reload() }
    catch (caught) { setNote(caught instanceof Error ? caught.message : 'That didn’t go through.') }
    finally { setResending(null) }
  }

  return <section className="admin-section" aria-busy={loading}>
    <header className="admin-section-head">
      <div><h2 data-page-heading tabIndex={-1}>Today</h2><p>Who needs you, and how your groups are doing.</p></div>
      <Button onClick={() => setInviting(true)} disabled={loading || groups.length === 0}>Invite people</Button>
    </header>
    {error && <p className="admin-alert error" role="alert">{error}</p>}
    {note && <p className="admin-alert success" role="status">{note}</p>}

    {loading ? <p role="status" className="admin-muted">Opening your day…</p> : groups.length === 0 ? <div className="admin-empty">
      <p>{currentUser.is_admin && activeCoachWorkspaceId === null ? 'Choose a program at the top to see its groups.' : 'You don’t have a group yet. Create one, then invite your people.'}</p>
      {!(currentUser.is_admin && activeCoachWorkspaceId === null) && <Button onClick={() => navigateTo(adminPath('groups'))}>Create a group</Button>}
    </div> : <>
      <h3 className="admin-subhead">Needs you</h3>
      {needs.length === 0 ? <p className="admin-muted admin-all-clear" role="status">{checking ? 'Checking…' : unreadable.length === live.length ? 'You can see individual requests only for the groups you coach. Open Support for setup requests.' : 'No one has asked for help.'}</p> : <ul className="admin-list">{needs.map(item => <li key={`${item.group.id}:${item.person.participant.id}`}>
        <button type="button" className="admin-list-row" onClick={() => setOpen(item)}>
          <strong>{item.person.participant.name}</strong><span className="admin-need">{dailyNeed(item.person)}</span><span>{item.group.name}</span>
        </button></li>)}</ul>}

      {needs.length > 0 && unreadable.length > 0 && <p className="admin-muted">Some groups aren’t listed because you don’t coach them.</p>}

      {followUps.length > 0 && <>
        <h3 className="admin-subhead">Invitations to follow up</h3>
        <ul className="admin-list">{followUps.slice(0, FOLLOW_UPS).map(person => <li key={person.id} className="admin-follow-row">
          <div><strong>{person.full_name || person.email}</strong>
            <span>{inviteStateOf(person) === 'bounced' ? 'The email didn’t arrive' : `Invited ${shortDay(person.invited_at) || 'recently'}, not joined yet`} · {person.cohorts.map(item => item.cohort.name).join(', ')}</span></div>
          {person.can_resend_invitation && <Button variant="secondary" disabled={resending !== null} onClick={() => void resend(person)}>{resending === person.id ? 'Sending…' : 'Send again'}</Button>}
        </li>)}</ul>
        {followUps.length > FOLLOW_UPS && <Button variant="secondary" onClick={() => navigateTo(adminPath('people'))}>See all {followUps.length} in People</Button>}
      </>}

      <h3 className="admin-subhead">Your groups</h3>
      <ul className="admin-list">{groups.filter(group => group.status !== 'archived').map(group => {
        const counts = daily[group.id]?.page?.counts
        return <li key={group.id}><button type="button" className="admin-list-row" onClick={() => navigateTo(adminPath('groups'))}>
          <strong>{group.name}</strong>
          <span>{groupLine(group, joinedCount(people, group.id)).replace(`${group.name} · `, '')}</span>
          {counts && group.savings_challenge?.enabled && group.savings_challenge.state === 'open' && <span>{counts.checked_in ?? 0} checked in today · {counts.needs_help} need you</span>}
        </button></li>
      })}</ul>
    </>}

    {inviting && <InvitePeople currentUser={currentUser} groups={groups} people={people} defaultGroupId={live[0]?.id ?? null} onClose={() => setInviting(false)} onDone={() => void reload()} />}
    {open && <AdminDialog title={open.person.participant.name} labelId="admin-need-title" onClose={() => setOpen(null)}>
      <p className="admin-muted">{open.group.name}</p>
      <p className="admin-need-line">{dailyNeed(open.person)}</p>
      {open.person.setup_help.length > 0 && <SetupSupportInbox actorId={currentUser.id} workspaceId={activeCoachWorkspaceId} cohortId={open.group.id} participantId={open.person.participant.id} isAdmin={currentUser.is_admin} />}
      {open.person.enrollment_id !== null && <ParticipantHelp row={{ ...open.person, enrollment_id: open.person.enrollment_id, check_in: open.person.check_in! }} />}
      {open.person.enrollment_id === null && open.person.setup_help.length === 0 && <p className="admin-muted">Private money details and conversations stay private.</p>}
    </AdminDialog>}
  </section>
}
