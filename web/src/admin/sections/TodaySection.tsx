import { useEffect, useMemo, useRef, useState } from 'react'
import { ApiRequestError, resendAdminUserInvitation, type AdminUser, type CurrentUser } from '../../api'
import { Button } from '../../components/Button'
import { ParticipantHelp } from '../../components/ParticipantHelp'
import { SetupSupportInbox } from '../../components/SetupSupportInbox'
import { useCoachWorkspaceMutationLifecycle, useHoldWorkspaceLock } from '../../components/coachWorkspaceMutationLifecycle'
import { useAuthContext } from '../../contexts/authContextValue'
import { adminPath, navigateTo } from '../../lib/appRoutes'
import { coachChallengeApi, type CoachDailyPage, type CoachDailyPerson, type DailyFilter } from '../../lib/coachChallengeApi'
import { dailyNeed, householdStatus, savingsStatus } from '../../lib/coachDailyWords'
import { AdminDialog } from '../AdminDialog'
import { groupLine, groupStatusLabel, inviteStateOf, shortDay } from '../adminWords'
import { joinedCount, useAdminRoster, type RosterGroup } from '../useAdminRoster'
import { InvitePeople } from './InvitePeople'
import './sections.css'

const FOLLOW_UPS = 5
// Today reads one page of each group's people, a few groups at a time, and updates the screen once.
const AT_A_TIME = 4
// A group's first page, or why there is none: this person may not read it (a real 403), or it didn't load and can be tried again.
type Overview = Record<number, CoachDailyPage | 'denied' | 'failed'>

const savingsFilters: Array<[DailyFilter, string]> = [['all', 'Everyone'], ['needs_help', 'Need you'], ['checked_in', 'Checked in'], ['not_checked_in', 'No check-in today']]
const householdFilters: Array<[DailyFilter, string]> = [['all', 'Everyone'], ['needs_help', 'Need you'], ['invited', 'Invited'], ['joined', 'Joined'], ['setup_done', 'Setup done']]

const groupSummary = (group: RosterGroup, joined: number) => group.detail ? groupLine(group.detail, joined).replace(`${group.name} · `, '') : groupStatusLabel[group.status].toLowerCase()

// "Who needs me today?" The people in a group first (those who need you at the top), then invitations that went nowhere.
export function TodaySection({ currentUser }: { currentUser: CurrentUser }) {
  const { activeCoachWorkspaceId } = useAuthContext()
  const { groups, people, access, loading, error, reload } = useAdminRoster(currentUser)
  const [overview, setOverview] = useState<Overview>({})
  const [chosen, setChosen] = useState<number | null>(null)
  const [inviting, setInviting] = useState(false)
  const [resending, setResending] = useState<number | null>(null)
  const [note, setNote] = useState<string | null>(null)
  const [attempt, setAttempt] = useState(0)
  useHoldWorkspaceLock(resending !== null)
  const live = useMemo(() => groups.filter(group => group.status !== 'archived' && group.status !== 'completed'), [groups])

  useEffect(() => {
    const controller = new AbortController()
    async function read() {
      const next: Overview = {}
      for (let start = 0; start < live.length; start += AT_A_TIME) {
        await Promise.all(live.slice(start, start + AT_A_TIME).map(group => coachChallengeApi.daily(group.id, '', 'needs_help', 0, controller.signal)
          .then(page => { next[group.id] = page.cohort_id === group.id ? page : 'failed' })
          // A group whose people list this person may not read simply has no list here; any other failure can be tried again.
          .catch(caught => { if (!controller.signal.aborted) next[group.id] = caught instanceof ApiRequestError && caught.status === 403 ? 'denied' : 'failed' })))
        if (controller.signal.aborted) return
      }
      setOverview(next)
    }
    queueMicrotask(() => void read())
    return () => controller.abort()
  }, [live, attempt])

  const pageOf = (group: RosterGroup) => { const found = overview[group.id]; return typeof found === 'object' ? found : null }
  const checking = live.some(group => !(group.id in overview))
  const readable = live.filter(group => pageOf(group))
  const unavailable = live.filter(group => overview[group.id] === 'failed')
  const needing = (group: RosterGroup) => pageOf(group)?.counts.needs_help ?? 0
  const activeId = readable.some(group => group.id === chosen) ? chosen : (readable.find(group => needing(group) > 0) ?? readable[0])?.id ?? null
  const active = live.find(group => group.id === activeId) ?? null
  const activePage = active ? pageOf(active) : null
  const tryAgain = () => { setOverview({}); setAttempt(value => value + 1) }
  const followUps = people.filter(person => person.role === 'participant' && person.cohorts.length > 0 && ['invited', 'bounced'].includes(inviteStateOf(person)))
    .sort((a, b) => Number(inviteStateOf(b) === 'bounced') - Number(inviteStateOf(a) === 'bounced'))
  const canInvite = access.people
  const platform = currentUser.is_admin && activeCoachWorkspaceId === null

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
      {canInvite && <Button onClick={() => setInviting(true)} disabled={loading || groups.length === 0}>Invite people</Button>}
    </header>
    {error && <p className="admin-alert error" role="alert">{error} <Button variant="secondary" size="compact" onClick={() => void reload()}>Try again</Button></p>}
    {note && <p className="admin-alert success" role="status">{note}</p>}

    {loading ? <p role="status" className="admin-muted">Opening your day…</p> : groups.length === 0 ? <div className="admin-empty">
      <p>{platform ? 'Choose a program at the top to see its groups.' : access.groups ? 'You don’t have a group yet. Create one, then invite your people.' : 'You aren’t on a group’s team yet. A program owner can add you to one.'}</p>
      {!platform && access.groups && <Button onClick={() => navigateTo(adminPath('groups'))}>Create a group</Button>}
    </div> : <>
      {readable.length > 1 && <label className="admin-field admin-today-group"><span>Group</span>
        <select value={activeId ?? ''} onChange={event => setChosen(Number(event.target.value))}>{readable.map(group => <option key={group.id} value={group.id}>{group.name}{needing(group) > 0 ? ` · ${needing(group)} ${needing(group) === 1 ? 'needs' : 'need'} you` : ''}</option>)}</select>
      </label>}
      {!checking && unavailable.length > 0 && <p className="admin-alert error" role="alert">We couldn’t load the people in {unavailable.map(group => group.name).join(', ')}. <Button variant="secondary" size="compact" onClick={tryAgain}>Try again</Button></p>}
      {active && activePage ? <DailyList key={active.id} group={active} overview={activePage} currentUser={currentUser} workspaceId={activeCoachWorkspaceId} canInvite={canInvite} onInvite={() => setInviting(true)} />
        : checking ? <p className="admin-muted admin-all-clear" role="status">Checking…</p>
        : unavailable.length === 0 && <p className="admin-muted admin-all-clear" role="status">You can see individual people only in the groups you coach. Support has the setup requests.</p>}

      {followUps.length > 0 && <>
        <h3 className="admin-subhead">Invitations to follow up</h3>
        <ul className="admin-list">{followUps.slice(0, FOLLOW_UPS).map(person => <li key={person.id} className="admin-follow-row">
          <div><strong>{person.full_name || person.email}</strong>
            <span>{[inviteStateOf(person) === 'bounced' ? 'The email didn’t arrive' : `Invited ${shortDay(person.invited_at) || 'recently'}, not joined yet`, person.cohorts.map(item => item.cohort.name).join(', ')].filter(Boolean).join(' · ')}</span></div>
          {person.can_resend_invitation && <Button variant="secondary" disabled={resending !== null} onClick={() => void resend(person)}>{resending === person.id ? 'Sending…' : 'Send again'}</Button>}
        </li>)}</ul>
        {followUps.length > FOLLOW_UPS && <Button variant="secondary" onClick={() => navigateTo(adminPath('people'))}>See all {followUps.length} in People</Button>}
      </>}

      <h3 className="admin-subhead">Your groups</h3>
      <ul className="admin-list">{groups.filter(group => group.status !== 'archived').map(group => {
        const counts = pageOf(group)?.counts
        const line = <><strong>{group.name}</strong>
          <span>{groupSummary(group, joinedCount(people, group.id))}</span>
          {counts && group.savingsChallenge && group.detail?.savings_challenge?.state === 'open' && <span>{counts.checked_in ?? 0} checked in today · {counts.needs_help} need you</span>}</>
        return <li key={group.id}>{access.groups
          ? <button type="button" className="admin-list-row" onClick={() => navigateTo(adminPath('groups'))}>{line}</button>
          : <div className="admin-list-row admin-list-static">{line}</div>}</li>
      })}</ul>
    </>}

    {inviting && <InvitePeople currentUser={currentUser} groups={groups} people={people} defaultGroupId={null} onClose={() => setInviting(false)} onDone={() => void reload()} />}
  </section>
}

// One group's people for today. Counts come from the server for the whole group, and every chip's list pages with "Show more".
function DailyList({ group, overview, currentUser, workspaceId, canInvite, onInvite }: {
  group: RosterGroup
  overview: CoachDailyPage
  currentUser: CurrentUser
  workspaceId: number | null
  canInvite: boolean
  onInvite: () => void
}) {
  const savings = overview.program_type === 'savings'
  const filters = savings ? savingsFilters : householdFilters
  const [filter, setFilter] = useState<DailyFilter>(overview.counts.needs_help > 0 ? 'needs_help' : 'all')
  const [search, setSearch] = useState('')
  const [records, setRecords] = useState<CoachDailyPerson[]>(filter === 'needs_help' ? overview.records : [])
  const [counts, setCounts] = useState(overview.counts)
  const [next, setNext] = useState<number | null>(filter === 'needs_help' ? overview.next_offset : null)
  const [total, setTotal] = useState(overview.total)
  const [busy, setBusy] = useState(filter !== 'needs_help')
  const [more, setMore] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [open, setOpen] = useState<CoachDailyPerson | null>(null)
  const [attempt, setAttempt] = useState(0)
  const request = useRef(0)
  const first = useRef(true)
  const lifecycle = useCoachWorkspaceMutationLifecycle(workspaceId)

  // The first page the screen already has is not asked for twice.
  useEffect(() => {
    if (first.current && filter === 'needs_help' && !search && attempt === 0) { first.current = false; return }
    first.current = false
    const mine = ++request.current
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      setBusy(true); setError(null)
      coachChallengeApi.daily(group.id, search, filter, 0, controller.signal).then(page => {
        if (mine !== request.current) return
        if (page.cohort_id !== group.id) throw new Error('The group changed. Open Today again.')
        setRecords(page.records); setCounts(page.counts); setTotal(page.total); setNext(page.next_offset); setBusy(false)
      }).catch(caught => {
        if (mine !== request.current || controller.signal.aborted) return
        setError(caught instanceof Error ? caught.message : 'These people couldn’t be loaded.'); setRecords([]); setNext(null); setBusy(false)
      })
    }, search ? 200 : 0)
    return () => { controller.abort(); window.clearTimeout(timer) }
  }, [group.id, filter, search, attempt])

  // After a dialog closes: read the first page again without blanking the list, so focus stays on the row that was opened.
  const generation = request.current
  async function quietRefresh() {
    if (generation !== request.current) return
    if (next !== null || records.length > 20) return
    const mine = ++request.current
    try {
      const page = await coachChallengeApi.daily(group.id, search, filter, 0, new AbortController().signal)
      if (mine === request.current && page.cohort_id === group.id) { setRecords(page.records); setCounts(page.counts); setTotal(page.total); setNext(page.next_offset) }
    } catch { /* The list on screen is still right; the next change reads it again. */ }
  }

  async function showMore() {
    if (next === null || more) return
    const mine = request.current
    setMore(true); setError(null)
    try {
      const page = await coachChallengeApi.daily(group.id, search, filter, next, new AbortController().signal)
      if (mine !== request.current) return
      // A person who moved between pages is shown once.
      setRecords(current => [...current, ...page.records.filter(row => !current.some(item => item.participant.id === row.participant.id))])
      setCounts(page.counts); setTotal(page.total); setNext(page.next_offset)
    } catch (caught) { if (mine === request.current) setError(caught instanceof Error ? caught.message : 'More people couldn’t be loaded.') }
    finally { setMore(false) }
  }

  const detail = group.detail
  return <div className="admin-daily">
    <h3 className="admin-subhead">{group.name}</h3>
    {detail && <p className="admin-muted">{groupLine(detail, counts.joined ?? 0).replace(`${group.name} · `, '')}</p>}
    <div className="admin-chips" role="group" aria-label="Show people who">
      {filters.map(([value, label]) => <button key={value} type="button" aria-pressed={filter === value} onClick={() => setFilter(value)}><strong>{counts[value] ?? 0}</strong> {label}</button>)}
    </div>
    <label className="admin-field"><span>Find someone</span><input type="search" value={search} placeholder="Name" onChange={event => setSearch(event.target.value)} /></label>
    {error && <p className="admin-alert error" role="alert">{error} <Button variant="secondary" size="compact" onClick={() => setAttempt(value => value + 1)}>Try again</Button></p>}
    {busy ? <p role="status" className="admin-muted">Loading people…</p>
      : records.length === 0 && !error ? <div className="admin-empty"><p>{search || filter !== 'all' ? (filter === 'needs_help' && !search ? 'No one has asked for help.' : 'No one matches. Try another name or choose Everyone.') : 'No one in this group yet. Invite someone to get started.'}</p>{canInvite && !search && filter === 'all' && <Button onClick={onInvite}>Invite people</Button>}</div>
      : <ul className="admin-list">{records.map(row => <li key={row.participant.id} className="admin-follow-row">
        <div><strong>{row.participant.name}</strong>
          <span className={row.needs_help ? 'admin-need' : undefined}>{dailyNeed(row)}</span>
          <span>{savings ? savingsStatus(row) : householdStatus(row)}</span></div>
        <Button variant="secondary" aria-label={`${row.needs_help ? 'View help for' : 'View'} ${row.participant.name}`} onClick={() => setOpen(row)}>{row.needs_help ? 'View help' : 'View person'}</Button>
      </li>)}</ul>}
    {!busy && next !== null && <Button variant="secondary" disabled={more} onClick={() => void showMore()}>{more ? 'Loading…' : `Show more (${Math.max(0, total - records.length)} left)`}</Button>}

    {open && <AdminDialog title={open.participant.name} labelId="admin-need-title" onClose={() => { setOpen(null); void quietRefresh() }}>
      <p className="admin-muted">{group.name}</p>
      <p className="admin-need-line">{dailyNeed(open)}</p>
      <p className="admin-muted">{savings ? savingsStatus(open) : householdStatus(open)}</p>
      {open.setup_help.length > 0 && <SetupSupportInbox actorId={currentUser.id} workspaceId={workspaceId} cohortId={group.id} participantId={open.participant.id} isAdmin={currentUser.is_admin} mutationLifecycle={lifecycle} />}
      {open.enrollment_id !== null && <ParticipantHelp row={{ ...open, enrollment_id: open.enrollment_id, check_in: open.check_in! }} onTicketChanged={() => void quietRefresh()} />}
      {open.enrollment_id === null && open.setup_help.length === 0 && <p className="admin-muted">Private money details and conversations stay private.</p>}
    </AdminDialog>}
  </div>
}
