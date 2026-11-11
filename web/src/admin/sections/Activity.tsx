import { useMemo, useState } from 'react'
import type { AdminCohort } from '../../api'
import { lastActiveWords } from '../adminWords'

type Entry = { key: string; at: string; who: string; what: string; why: string; group: string }

// What has been changed, newest first. It reads the group changes the server already records.
export function Activity({ groups }: { groups: AdminCohort[] }) {
  const [groupId, setGroupId] = useState('')
  const [person, setPerson] = useState('')
  const entries: Entry[] = useMemo(() => groups.flatMap(group => (group.savings_challenge?.recent_events ?? []).map(event => ({
    key: `${group.id}:${event.id}`, at: event.occurred_at, who: event.actor_name,
    what: `${event.action === 'open' ? 'Opened' : 'Paused'} the savings challenge`, why: event.reason, group: group.name,
  }))).filter(item => !groupId || groups.find(group => String(group.id) === groupId)?.name === item.group)
    .filter(item => !person.trim() || item.who.toLowerCase().includes(person.trim().toLowerCase()))
    .sort((a, b) => new Date(b.at).getTime() - new Date(a.at).getTime()), [groupId, groups, person])
  return <div className="admin-activity">
    <div className="admin-toolbar">
      <label className="admin-field"><span>Who made the change</span><input type="search" value={person} placeholder="A name" onChange={event => setPerson(event.target.value)} /></label>
      <label className="admin-field"><span>Group</span><select value={groupId} onChange={event => setGroupId(event.target.value)}><option value="">All groups</option>{groups.map(group => <option key={group.id} value={group.id}>{group.name}</option>)}</select></label>
    </div>
    {entries.length === 0 ? <p className="admin-muted">No changes to show.</p> : <ul className="admin-list">{entries.map(item => <li key={item.key} className="admin-activity-row">
      <strong>{item.what}</strong><span>{item.group} · {item.who} · {lastActiveWords(item.at)}</span><span>“{item.why}”</span>
    </li>)}</ul>}
  </div>
}
