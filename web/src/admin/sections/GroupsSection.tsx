import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react'
import { createAdminCohort, fetchAdminPersonaAssignableCohorts, updateAdminCohort } from '../../api'
import type { AdminCohort, AdminCohortStatus, AdminPersonaAssignableCohort, CurrentUser } from '../../api'
import { Button } from '../../components/Button'
import { CohortExperienceStudio } from '../../components/CohortExperienceStudio'
import { SavingsChallengeAccessPanel } from '../../components/SavingsChallengeAccessPanel'
import { useCoachWorkspaceMutationLifecycle } from '../../components/coachWorkspaceMutationLifecycle'
import { useAuthContext } from '../../contexts/authContextValue'
import { adminPath, navigateTo } from '../../lib/appRoutes'
import { useMatchMedia } from '../../lib/useMatchMedia'
import { AdminDialog } from '../AdminDialog'
import { groupLine, groupStatusLabel, shortDay } from '../adminWords'
import { joinedCount, useAdminRoster } from '../useAdminRoster'
import './sections.css'

const message = (caught: unknown, fallback: string) => caught instanceof Error ? caught.message : fallback
const statuses: AdminCohortStatus[] = ['draft', 'enrolling', 'active', 'completed', 'archived']
const dates = (group: AdminCohort) => group.starts_on && group.ends_on ? `${shortDay(group.starts_on)} – ${shortDay(group.ends_on)}` : group.starts_on ? `Starts ${shortDay(group.starts_on)}` : 'No dates yet'
const challengeWords = (group: AdminCohort) => !group.savings_challenge?.enabled ? '—' : ({ open: 'Open', paused: 'Paused', ready: 'Ready to open', not_set_up: 'Not set up yet' })[group.savings_challenge.state]

export function GroupsSection({ currentUser, onDirtyChange }: { currentUser: CurrentUser; onDirtyChange: (dirty: boolean) => void }) {
  const { activeCoachWorkspaceId } = useAuthContext()
  const { groups, people, loading, error, reload } = useAdminRoster()
  const wide = useMatchMedia('(min-width: 840px)')
  const [openId, setOpenId] = useState<number | null>(null)
  const [creating, setCreating] = useState(false)
  const open = groups.find(group => group.id === openId) ?? null
  const platformMode = currentUser.is_admin && activeCoachWorkspaceId === null
  const visibleGroups = useMemo(() => groups.filter(group => group.status !== 'archived'), [groups])

  if (open) return <GroupPage group={open} joined={joinedCount(people, open.id)} onBack={() => setOpenId(null)} reload={reload} onDirtyChange={onDirtyChange} />
  return <section className="admin-section" aria-busy={loading}>
    <header className="admin-section-head">
      <div><h2 data-page-heading tabIndex={-1}>Groups</h2><p>Each group has its own dates, tools and challenge.</p></div>
      <Button onClick={() => setCreating(true)} disabled={loading}>New group</Button>
    </header>
    {error && <p className="admin-alert error" role="alert">{error} <Button variant="secondary" size="compact" onClick={() => void reload()}>Try again</Button></p>}
    {loading ? <p role="status" className="admin-muted">Opening your groups…</p>
      : visibleGroups.length === 0 ? <div className="admin-empty"><p>No groups yet. A group is a set of people you coach together.</p><Button onClick={() => setCreating(true)}>Create your first group</Button></div>
      : wide ? <div className="admin-table-wrap"><table className="admin-table">
        <thead><tr><th scope="col">Group</th><th scope="col">Status</th><th scope="col">Dates</th><th scope="col">Joined</th><th scope="col">Challenge</th></tr></thead>
        <tbody>{visibleGroups.map(group => <tr key={group.id}>
          <th scope="row"><button type="button" className="admin-row-link" onClick={() => setOpenId(group.id)}><strong>{group.name}</strong></button></th>
          <td>{groupStatusLabel[group.status]}</td><td>{dates(group)}</td>
          <td>{joinedCount(people, group.id)}{group.savings_challenge?.enabled ? ` of ${group.savings_challenge.capacity}` : ''}</td><td>{challengeWords(group)}</td>
        </tr>)}</tbody>
      </table></div>
      : <ul className="admin-list">{visibleGroups.map(group => <li key={group.id}><button type="button" className="admin-list-row" onClick={() => setOpenId(group.id)}>
        <strong>{group.name}</strong>
        <span>{groupLine(group, joinedCount(people, group.id)).replace(`${group.name} · `, '')}</span>
      </button></li>)}</ul>}
    {creating && <NewGroup platformMode={platformMode} onClose={() => setCreating(false)} onCreated={async group => { setCreating(false); await reload(); setOpenId(group.id) }} />}
  </section>
}

function NewGroup({ platformMode, onClose, onCreated }: { platformMode: boolean; onClose: () => void; onCreated: (group: AdminCohort) => Promise<void> }) {
  const [name, setName] = useState('')
  const [starts, setStarts] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  async function submit(event: FormEvent) {
    event.preventDefault()
    if (busy) return
    if (platformMode) { setError('Choose a program at the top of the page first, so the group has a home.'); return }
    if (!name.trim()) { setError('Give the group a name.'); return }
    setBusy(true); setError(null)
    try { await onCreated(await createAdminCohort({ name: name.trim(), status: 'enrolling', ...(starts ? { starts_on: starts } : {}) })) }
    catch (caught) { setError(message(caught, 'The group couldn’t be created. Try again.')); setBusy(false) }
  }
  return <AdminDialog title="New group" labelId="admin-new-group-title" onClose={onClose}>
    <form className="admin-stack" onSubmit={submit} noValidate>
      <label className="admin-field"><span>Group name</span><input autoFocus maxLength={120} value={name} placeholder="Tuesday evening group" onChange={event => setName(event.target.value)} /></label>
      <label className="admin-field"><span>Start date (optional)</span><input type="date" value={starts} onChange={event => setStarts(event.target.value)} /></label>
      {error && <p className="admin-alert error" role="alert">{error}</p>}
      <div className="admin-actions"><Button type="submit" disabled={busy}>{busy ? 'Creating…' : 'Create group'}</Button></div>
    </form>
  </AdminDialog>
}

type Draft = { name: string; status: AdminCohortStatus; starts_on: string; ends_on: string; notes: string }
const draftFor = (group: AdminCohort): Draft => ({ name: group.name, status: group.status, starts_on: group.starts_on ?? '', ends_on: group.ends_on ?? '', notes: group.notes ?? '' })

function GroupPage({ group, joined, onBack, reload, onDirtyChange }: { group: AdminCohort; joined: number; onBack: () => void; reload: () => Promise<void>; onDirtyChange: (dirty: boolean) => void }) {
  const { activeCoachWorkspaceId } = useAuthContext()
  const lifecycle = useCoachWorkspaceMutationLifecycle(activeCoachWorkspaceId)
  const [tab, setTab] = useState<'details' | 'tools'>('details')
  const [draft, setDraft] = useState<Draft>(() => draftFor(group))
  const [assignable, setAssignable] = useState<AdminPersonaAssignableCohort[]>([])
  const [selected, setSelected] = useState<number | null>(group.id)
  const [saving, setSaving] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [toolsDirty, setToolsDirty] = useState(false)
  const [challengeBusy, setChallengeBusy] = useState(false)
  const [challengeDirty, setChallengeDirty] = useState(false)
  const detailsDirty = JSON.stringify(draft) !== JSON.stringify(draftFor(group))
  const voice = assignable.find(item => item.id === group.id)?.persona_assignment?.persona.name

  useEffect(() => { onDirtyChange(detailsDirty || toolsDirty || challengeDirty) }, [detailsDirty, toolsDirty, challengeDirty, onDirtyChange])
  useEffect(() => () => onDirtyChange(false), [onDirtyChange])
  useEffect(() => {
    let live = true
    fetchAdminPersonaAssignableCohorts().then(next => { if (live) setAssignable(next) }).catch(() => { /* The voice line is a convenience; the page works without it. */ })
    return () => { live = false }
  }, [])

  async function save(event: FormEvent) {
    event.preventDefault()
    if (saving || !draft.name.trim()) return
    setSaving(true); setError(null); setNotice(null)
    try {
      await updateAdminCohort(group.id, { ...draft, name: draft.name.trim(), expected_updated_at: group.updated_at })
      await reload()
      setNotice('Saved.')
    } catch (caught) { setError(message(caught, 'The group couldn’t be saved. Try again.')) }
    finally { setSaving(false) }
  }
  const afterChallengeChange = useCallback(async () => { await reload() }, [reload])
  const setTool = (next: 'details' | 'tools') => setTab(next)

  return <section className="admin-section">
    <header className="admin-section-head admin-group-head">
      <div>
        <button type="button" className="admin-back" onClick={onBack}>‹ All groups</button>
        <h2 data-page-heading tabIndex={-1}>{group.name}</h2>
        <p>{groupLine(group, joined).replace(`${group.name} · `, '')}</p>
      </div>
    </header>
    {group.savings_challenge?.enabled && <SavingsChallengeAccessPanel key={group.id} cohort={group} busy={saving || challengeBusy} onChanged={afterChallengeChange} onDirtyChange={setChallengeDirty} onPendingChange={setChallengeBusy} />}
    <div className="admin-chips" role="group" aria-label="Group settings">
      <button type="button" aria-pressed={tab === 'details'} onClick={() => setTool('details')}>Details</button>
      <button type="button" aria-pressed={tab === 'tools'} onClick={() => setTool('tools')}>Tools people can use</button>
    </div>
    {tab === 'details' ? <>
      <form className="admin-stack admin-group-form" onSubmit={save}>
        <label className="admin-field"><span>Group name</span><input maxLength={120} value={draft.name} onChange={event => setDraft({ ...draft, name: event.target.value })} /></label>
        <label className="admin-field"><span>Where it stands</span>
          <select value={draft.status} onChange={event => setDraft({ ...draft, status: event.target.value as AdminCohortStatus })}>{statuses.map(value => <option key={value} value={value}>{groupStatusLabel[value]}</option>)}</select>
          <small>This only organizes your groups. It doesn’t open anything for people.</small>
        </label>
        <div className="admin-pair">
          <label className="admin-field"><span>Starts</span><input type="date" value={draft.starts_on} onChange={event => setDraft({ ...draft, starts_on: event.target.value })} /></label>
          <label className="admin-field"><span>Ends (optional)</span><input type="date" min={draft.starts_on || undefined} value={draft.ends_on} onChange={event => setDraft({ ...draft, ends_on: event.target.value })} /></label>
        </div>
        <label className="admin-field"><span>Notes (only you see these)</span><textarea rows={3} maxLength={2000} value={draft.notes} onChange={event => setDraft({ ...draft, notes: event.target.value })} /></label>
        {error && <p className="admin-alert error" role="alert">{error}</p>}
        {notice && <p className="admin-alert success" role="status">{notice}</p>}
        <div className="admin-actions"><Button type="submit" disabled={saving || !detailsDirty || !draft.name.trim()}>{saving ? 'Saving…' : 'Save group'}</Button></div>
      </form>
      <div className="admin-voice-line">
        <p><strong>Coach voice:</strong> {voice ?? 'The standard Mia voice'}</p>
        <Button variant="secondary" onClick={() => navigateTo(adminPath('coaching'))}>Change the voice</Button>
      </div>
      {group.operational_summary?.available && <p className="admin-muted">Last 7 days: {group.operational_summary.participants_active} {group.operational_summary.participants_active === 1 ? 'person' : 'people'} active, {group.operational_summary.mia_requests} {group.operational_summary.mia_requests === 1 ? 'question' : 'questions'} to Mia, {group.operational_summary.uploads} {group.operational_summary.uploads === 1 ? 'upload' : 'uploads'}. Amounts and conversations stay private.</p>}
    </> : <div className="admin-tools">
      <CohortExperienceStudio simple fixedGroup cohorts={assignable.filter(item => item.id === group.id)} cohortsLoading={assignable.length === 0} selectedCohortId={selected} onSelectedCohortIdChange={setSelected} mutationLifecycle={lifecycle} onDirtyChange={setToolsDirty} />
    </div>}
  </section>
}
