import { AdminScope } from '../AdminScope'
import { useEffect, useMemo, useRef, useState } from 'react'
import type { AdminUser, CurrentUser, UserRole } from '../../api'
import { Button } from '../../components/Button'
import { useMatchMedia } from '../../lib/useMatchMedia'
import { groupNames, inviteStateLabel, inviteStateOf, lastActiveAt, lastActiveWords, roleLabel, setupWords, type InviteState } from '../adminWords'
import { useAdminRoster } from '../useAdminRoster'
import { InvitePeople } from './InvitePeople'
import { PersonDetail } from './PersonDetail'
import './sections.css'

type StateFilter = 'everyone' | InviteState
type SortKey = 'name' | 'email' | 'status' | 'active' | 'setup'
const PAGE = 10

const filters: Array<[StateFilter, string]> = [['everyone', 'Everyone'], ['joined', 'Joined'], ['invited', 'Invited'], ['bounced', 'Email didn’t arrive'], ['removed', 'Removed']]
const sortChoices: Array<[SortKey, string]> = [['name', 'Name'], ['email', 'Email'], ['status', 'Invitation'], ['active', 'Last active'], ['setup', 'Setup']]
const roleChoices: Array<[UserRole | '', string]> = [['', 'Everyone'], ['participant', 'Participants'], ['coach', 'Coaches'], ['admin', 'Admins']]
// What needs attention sorts first: an email that bounced, then one not yet accepted.
const statusRank: Record<InviteState, number> = { bounced: 0, invited: 1, joined: 2, removed: 3 }
const setupRank = (person: AdminUser) => ({ 'Not started': 0, 'Setup started': 1, 'Setup done': 2 } as Record<string, number>)[setupWords(person)] ?? 3
const nameOf = (person: AdminUser) => person.full_name || person.email
const activeTime = (person: AdminUser) => lastActiveAt(person) ? new Date(lastActiveAt(person)!).getTime() : 0

export function PeopleSection({ currentUser }: { currentUser: CurrentUser }) {
  const { groups, people, loading, error, reload } = useAdminRoster(currentUser)
  const wide = useMatchMedia('(min-width: 840px)')
  const phone = useMatchMedia('(max-width: 620px)')
  const [filtersOpen, setFiltersOpen] = useState(false)
  const [search, setSearch] = useState('')
  const [groupId, setGroupId] = useState('')
  const [role, setRole] = useState<UserRole | ''>('')
  const [filter, setFilter] = useState<StateFilter>('everyone')
  const [sort, setSort] = useState<{ key: SortKey; descending: boolean }>({ key: 'name', descending: false })
  const [openId, setOpenId] = useState<number | null>(null)
  const [inviting, setInviting] = useState(false)
  const [shown, setShown] = useState(PAGE)
  const [note, setNote] = useState<string | null>(null)
  const heading = useRef<HTMLHeadingElement>(null)
  // When a person leaves the list the dialog's own row is gone, so the page heading takes focus once the dialog has closed.
  useEffect(() => { if (note) heading.current?.focus({ preventScroll: true }) }, [note])
  // Only platform administrators see whether an email arrived; for everyone else the chip would always read 0.
  const showsDelivery = people.some(person => person.invite_email.status !== 'hidden')
  const mixedRoles = people.some(person => person.role !== 'participant')
  const filterChoices = showsDelivery ? filters : filters.filter(([value]) => value !== 'bounced')

  const inGroup = useMemo(() => people.filter(person => (!groupId || person.cohorts.some(item => String(item.cohort.id) === groupId)) && (!role || person.role === role)), [people, groupId, role])
  const counts = useMemo(() => {
    const result: Record<StateFilter, number> = { everyone: 0, joined: 0, invited: 0, bounced: 0, removed: 0 }
    for (const person of inGroup) { const state = inviteStateOf(person); result[state] += 1; if (state !== 'removed') result.everyone += 1 }
    return result
  }, [inGroup])
  const rows = useMemo(() => {
    const needle = search.trim().toLowerCase()
    const matching = inGroup.filter(person => (filter === 'everyone' ? inviteStateOf(person) !== 'removed' : inviteStateOf(person) === filter) && (!needle || `${person.full_name} ${person.email}`.toLowerCase().includes(needle)))
    const direction = sort.descending ? -1 : 1
    const compare = (a: AdminUser, b: AdminUser) => {
      switch (sort.key) {
        case 'email': return a.email.localeCompare(b.email)
        case 'status': return statusRank[inviteStateOf(a)] - statusRank[inviteStateOf(b)]
        case 'active': return activeTime(a) - activeTime(b)
        case 'setup': return setupRank(a) - setupRank(b)
        default: return nameOf(a).localeCompare(nameOf(b))
      }
    }
    return [...matching].sort((a, b) => compare(a, b) * direction || nameOf(a).localeCompare(nameOf(b)))
  }, [filter, inGroup, search, sort])
  const visible = wide ? rows : rows.slice(0, shown)
  const open = people.find(person => person.id === openId) ?? null
  // Name and last active start the way a coach expects (A to Z, newest first); the rest start with what needs attention.
  const sortBy = (key: SortKey) => setSort(current => ({ key, descending: current.key === key ? !current.descending : key === 'active' }))
  const ariaSort = (key: SortKey) => sort.key === key ? (sort.descending ? 'descending' as const : 'ascending' as const) : 'none' as const
  const head = (key: SortKey, label: string) => <th scope="col" aria-sort={ariaSort(key)}><button type="button" onClick={() => sortBy(key)}>{label}</button></th>

  return <section className="admin-section" aria-busy={loading}>
    <header className="admin-section-head">
      <div><h2 ref={heading} data-page-heading tabIndex={-1}>People</h2><AdminScope currentUser={currentUser} /><p>Everyone you coach, and who has joined.</p></div>
      <Button onClick={() => setInviting(true)} disabled={loading}>Invite people</Button>
    </header>
    {error && <p className="admin-alert error" role="alert">{error} <Button variant="secondary" size="compact" onClick={() => void reload()}>Try again</Button></p>}
    {note && <p className="admin-alert success" role="status">{note}</p>}

    <div className="admin-people-filters">
      {phone && <button type="button" className="ui-chip admin-filter-toggle" aria-expanded={filtersOpen} aria-controls="admin-people-filter-fields" onClick={() => setFiltersOpen(open => !open)}>Filters ({Number(Boolean(groupId)) + Number(Boolean(role)) + Number(filter !== 'everyone') + Number(Boolean(search.trim()))})</button>}
    <div id="admin-people-filter-fields" hidden={phone && !filtersOpen} className="admin-filter-fields">
    <div className="admin-toolbar">
      <label className="admin-field"><span>Find someone</span><input type="search" value={search} placeholder="Name or email" onChange={event => { setSearch(event.target.value); setShown(PAGE) }} /></label>
      <label className="admin-field"><span>Group</span>
        <select value={groupId} onChange={event => { setGroupId(event.target.value); setShown(PAGE) }}><option value="">All groups</option>{groups.map(group => <option key={group.id} value={group.id}>{group.name}</option>)}</select>
      </label>
      {mixedRoles && <label className="admin-field"><span>Role</span>
        <select value={role} onChange={event => { setRole(event.target.value as UserRole | ''); setShown(PAGE) }}>{roleChoices.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select>
      </label>}
      <label className="admin-field"><span>Sort by</span>
        <select value={sort.key} onChange={event => { const key = event.target.value as SortKey; setSort({ key, descending: key === 'active' }) }}>{sortChoices.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select>
      </label>
    </div>
    <div className="admin-chips" role="group" aria-label="Show people who are">
      {filterChoices.map(([value, label]) => <button key={value} type="button" aria-pressed={filter === value} onClick={() => { setFilter(value); setShown(PAGE) }}><strong>{counts[value]}</strong> {label}</button>)}
    </div>

    </div></div>

    {loading ? <p role="status" className="admin-muted">Opening your people…</p>
      : rows.length === 0 ? <div className="admin-empty"><p>{people.length === 0 ? 'No one here yet.' : 'No one matches. Try another name or choose Everyone.'}</p>{people.length === 0 && <Button onClick={() => setInviting(true)}>Invite your first people</Button>}</div>
      : wide ? <div className="ui-card admin-table-wrap"><table className="admin-table">
        <thead><tr>
          {head('name', 'Name')}
          <th scope="col">Group</th><th scope="col">Role</th>
          {head('status', 'Invitation')}{head('active', 'Last active')}{head('setup', 'Setup')}
        </tr></thead>
        <tbody>{visible.map(person => <tr key={person.id}>
          <th scope="row"><button type="button" className="admin-row-link" onClick={() => setOpenId(person.id)}><strong>{nameOf(person)}</strong><small>{person.email}</small></button></th>
          <td><span className="admin-group-name" title={groupNames(person) || undefined}>{groupNames(person) || '—'}</span></td><td>{roleLabel[person.role]}</td>
          <td><StatePill person={person} /></td><td>{lastActiveWords(lastActiveAt(person))}</td><td className="admin-setup-status">{setupWords(person)}</td>
        </tr>)}</tbody>
      </table></div>
      : <ul className="ui-card ui-rows admin-list">{visible.map(person => <li key={person.id}><button type="button" className="admin-list-row admin-people-row" onClick={() => setOpenId(person.id)}>
        <strong>{nameOf(person)}</strong>
        <span className="admin-group-name" title={groupNames(person) || undefined}>{groupNames(person) || roleLabel[person.role]}</span>
        <span className="admin-list-meta"><StatePill person={person} /> · {lastActiveWords(lastActiveAt(person))}</span>
      </button></li>)}</ul>}
    {!wide && rows.length > visible.length && <Button variant="secondary" onClick={() => setShown(count => count + PAGE)}>Show {Math.min(PAGE, rows.length - visible.length)} more of {rows.length - visible.length}</Button>}

    {inviting && <InvitePeople currentUser={currentUser} groups={groups} people={people} defaultGroupId={groupId ? Number(groupId) : null} onClose={() => setInviting(false)} onDone={() => void reload()} />}
    {open && <PersonDetail key={open.id} person={open} groups={groups} currentUser={currentUser} onClose={() => setOpenId(null)} onChanged={reload} onRemoved={text => { setOpenId(null); setNote(text) }} />}
  </section>
}

export function StatePill({ person }: { person: AdminUser }) {
  const state = inviteStateOf(person)
  return <span className={`admin-pill is-${state}`}>{inviteStateLabel[state]}</span>
}
