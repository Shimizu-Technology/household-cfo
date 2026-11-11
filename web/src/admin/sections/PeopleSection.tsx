import { useMemo, useState } from 'react'
import type { AdminUser, CurrentUser } from '../../api'
import { Button } from '../../components/Button'
import { useMatchMedia } from '../../lib/useMatchMedia'
import { groupNames, inviteStateLabel, inviteStateOf, lastActiveAt, lastActiveWords, roleLabel, setupWords, type InviteState } from '../adminWords'
import { useAdminRoster } from '../useAdminRoster'
import { InvitePeople } from './InvitePeople'
import { PersonDetail } from './PersonDetail'
import './sections.css'

type StateFilter = 'everyone' | InviteState
type SortKey = 'name' | 'active'
const PAGE = 10

const filters: Array<[StateFilter, string]> = [['everyone', 'Everyone'], ['joined', 'Joined'], ['invited', 'Invited'], ['bounced', 'Email didn’t arrive'], ['removed', 'Removed']]

export function PeopleSection({ currentUser }: { currentUser: CurrentUser }) {
  const { groups, people, loading, error, reload } = useAdminRoster()
  const wide = useMatchMedia('(min-width: 840px)')
  const [search, setSearch] = useState('')
  const [groupId, setGroupId] = useState('')
  const [filter, setFilter] = useState<StateFilter>('everyone')
  const [sort, setSort] = useState<{ key: SortKey; descending: boolean }>({ key: 'name', descending: false })
  const [openId, setOpenId] = useState<number | null>(null)
  const [inviting, setInviting] = useState(false)
  const [shown, setShown] = useState(PAGE)

  const inGroup = useMemo(() => people.filter(person => !groupId || person.cohorts.some(item => String(item.cohort.id) === groupId)), [people, groupId])
  const counts = useMemo(() => {
    const result: Record<StateFilter, number> = { everyone: 0, joined: 0, invited: 0, bounced: 0, removed: 0 }
    for (const person of inGroup) { const state = inviteStateOf(person); result[state] += 1; if (state !== 'removed') result.everyone += 1 }
    return result
  }, [inGroup])
  const rows = useMemo(() => {
    const needle = search.trim().toLowerCase()
    const shown = inGroup.filter(person => (filter === 'everyone' ? inviteStateOf(person) !== 'removed' : inviteStateOf(person) === filter) && (!needle || `${person.full_name} ${person.email}`.toLowerCase().includes(needle)))
    const direction = sort.descending ? -1 : 1
    return [...shown].sort((a, b) => {
      if (sort.key === 'active') {
        const left = lastActiveAt(a) ? new Date(lastActiveAt(a)!).getTime() : 0
        const right = lastActiveAt(b) ? new Date(lastActiveAt(b)!).getTime() : 0
        return (left - right) * direction || nameOf(a).localeCompare(nameOf(b))
      }
      return nameOf(a).localeCompare(nameOf(b)) * direction
    })
  }, [filter, inGroup, search, sort])
  const visible = wide ? rows : rows.slice(0, shown)
  const open = people.find(person => person.id === openId) ?? null
  const sortBy = (key: SortKey) => setSort(current => ({ key, descending: current.key === key ? !current.descending : key === 'active' }))
  const ariaSort = (key: SortKey) => sort.key === key ? (sort.descending ? 'descending' as const : 'ascending' as const) : 'none' as const

  return <section className="admin-section" aria-busy={loading}>
    <header className="admin-section-head">
      <div><h2 data-page-heading tabIndex={-1}>People</h2><p>Everyone you coach, and who has joined.</p></div>
      <Button onClick={() => setInviting(true)} disabled={loading}>Invite people</Button>
    </header>
    {error && <p className="admin-alert error" role="alert">{error} <Button variant="secondary" size="compact" onClick={() => void reload()}>Try again</Button></p>}

    <div className="admin-toolbar">
      <label className="admin-field"><span>Find someone</span><input type="search" value={search} placeholder="Name or email" onChange={event => { setSearch(event.target.value); setShown(PAGE) }} /></label>
      <label className="admin-field"><span>Group</span>
        <select value={groupId} onChange={event => { setGroupId(event.target.value); setShown(PAGE) }}><option value="">All groups</option>{groups.map(group => <option key={group.id} value={group.id}>{group.name}</option>)}</select>
      </label>
    </div>
    <div className="admin-chips" role="group" aria-label="Show people who are">
      {filters.map(([value, label]) => <button key={value} type="button" aria-pressed={filter === value} onClick={() => { setFilter(value); setShown(PAGE) }}><strong>{counts[value]}</strong> {label}</button>)}
    </div>

    {loading ? <p role="status" className="admin-muted">Opening your people…</p>
      : rows.length === 0 ? <div className="admin-empty"><p>{people.length === 0 ? 'No one here yet.' : 'No one matches. Try another name or choose Everyone.'}</p>{people.length === 0 && <Button onClick={() => setInviting(true)}>Invite your first people</Button>}</div>
      : wide ? <div className="admin-table-wrap"><table className="admin-table">
        <thead><tr>
          <th scope="col" aria-sort={ariaSort('name')}><button type="button" onClick={() => sortBy('name')}>Name</button></th>
          <th scope="col">Group</th><th scope="col">Role</th><th scope="col">Invitation</th>
          <th scope="col" aria-sort={ariaSort('active')}><button type="button" onClick={() => sortBy('active')}>Last active</button></th>
          <th scope="col">Setup</th>
        </tr></thead>
        <tbody>{visible.map(person => <tr key={person.id}>
          <th scope="row"><button type="button" className="admin-row-link" onClick={() => setOpenId(person.id)}><strong>{nameOf(person)}</strong><small>{person.email}</small></button></th>
          <td>{groupNames(person) || '—'}</td><td>{roleLabel[person.role]}</td>
          <td><StatePill person={person} /></td><td>{lastActiveWords(lastActiveAt(person))}</td><td>{setupWords(person)}</td>
        </tr>)}</tbody>
      </table></div>
      : <ul className="admin-list">{visible.map(person => <li key={person.id}><button type="button" className="admin-list-row" onClick={() => setOpenId(person.id)}>
        <strong>{nameOf(person)}</strong>
        <span>{groupNames(person) || roleLabel[person.role]}</span>
        <span className="admin-list-meta"><StatePill person={person} /> · {lastActiveWords(lastActiveAt(person))}</span>
      </button></li>)}</ul>}
    {!wide && rows.length > visible.length && <Button variant="secondary" onClick={() => setShown(count => count + PAGE)}>Show {Math.min(PAGE, rows.length - visible.length)} more of {rows.length - visible.length}</Button>}

    {inviting && <InvitePeople currentUser={currentUser} groups={groups} people={people} defaultGroupId={groupId ? Number(groupId) : null} onClose={() => setInviting(false)} onDone={() => void reload()} />}
    {open && <PersonDetail key={open.id} person={open} groups={groups} currentUser={currentUser} onClose={() => setOpenId(null)} onChanged={reload} />}
  </section>
}

const nameOf = (person: AdminUser) => person.full_name || person.email

export function StatePill({ person }: { person: AdminUser }) {
  const state = inviteStateOf(person)
  return <span className={`admin-pill is-${state}`}>{inviteStateLabel[state]}</span>
}
