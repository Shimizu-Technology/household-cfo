import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import { createAdminCohort, createAdminUser, fetchAdminCohorts, fetchAdminUsers, fetchAdminPlaidHealth, updateAdminCohort, updateAdminUser, resendAdminUserInvitation } from '../api'
import type { AdminCohort, AdminCohortInput, AdminCohortStatus, AdminPlaidHealth, AdminUser, AdminUserInput, AdminUserMutationResponse, CurrentUser, InvitationStatus, UserRole } from '../api'
import { useAuthContext } from '../contexts/authContextValue'
import { PilotFeedbackInbox } from './PilotFeedbackInbox'
import { CreateCoachProgram } from './CoachProgramSettings'
import './AdminConsole.css'

type AdminUserDraft = {
  role: UserRole
  invitation_status: InvitationStatus
  cohort_ids: string[]
}

type UserStatusFilter = 'active' | 'all' | InvitationStatus
type UserRoleFilter = 'all' | UserRole
type UserSortKey = 'name_asc' | 'email_asc' | 'role_asc' | 'status_asc' | 'setup_desc' | 'invite_desc'

const cohortStatuses: AdminCohortStatus[] = ['draft', 'enrolling', 'active', 'completed', 'archived']
const userRoles: UserRole[] = ['participant', 'coach', 'admin']
const invitationStatuses: InvitationStatus[] = ['pending', 'accepted', 'revoked']
const emptyCohortOperationalSummary: AdminCohort['operational_summary'] = {
  available: false,
  period_days: 7,
  mia_requests: null,
  mia_failures: null,
  average_mia_latency_ms: null,
  uploads: null,
  upload_failures: null,
  participants_active: null,
}

export function AdminConsole({ currentUser }: { currentUser: CurrentUser }) {
  const { activeCoachWorkspaceId } = useAuthContext()
  return <AdminPanel key={`${currentUser.id}:${activeCoachWorkspaceId ?? 'platform'}`} currentUser={currentUser} />
}

function AdminPanel({ currentUser }: { currentUser: CurrentUser }) {
  const { activeCoachWorkspaceId, selectCoachWorkspace } = useAuthContext()
  const coachWorkspaces = currentUser.coach_workspaces ?? []
  const platformMode = currentUser.is_admin && activeCoachWorkspaceId === null
  const [area, setArea] = useState<'participants' | 'cohorts' | 'feedback' | 'programs' | 'health'>('participants')
  const [cohorts, setCohorts] = useState<AdminCohort[]>([])
  const [users, setUsers] = useState<AdminUser[]>([])
  const [plaidHealth, setPlaidHealth] = useState<AdminPlaidHealth>({ summary: { connected: 0, healthy: 0, attention_required: 0 }, items: [] })
  const [plaidHealthError, setPlaidHealthError] = useState<string | null>(null)
  const [selectedCohortId, setSelectedCohortId] = useState<number | null>(null)
  const [createDraft, setCreateDraft] = useState<AdminCohortInput>({
    name: '',
    status: 'enrolling',
    starts_on: '',
    ends_on: '',
    notes: '',
  })
  const [editDraft, setEditDraft] = useState<AdminCohortInput | null>(null)
  const [inviteDraft, setInviteDraft] = useState<AdminUserInput>({
    email: '',
    role: 'participant',
    cohort_id: '',
    send_invitation_email: true,
  })
  const [userDrafts, setUserDrafts] = useState<Record<number, AdminUserDraft>>({})
  const [rosterPage, setRosterPage] = useState(0)
  const [userSearch, setUserSearch] = useState('')
  const [userStatusFilter, setUserStatusFilter] = useState<UserStatusFilter>('active')
  const [userRoleFilter, setUserRoleFilter] = useState<UserRoleFilter>('all')
  const [userSort, setUserSort] = useState<UserSortKey>('name_asc')
  const [loading, setLoading] = useState(true)
  const [cohortSaving, setCohortSaving] = useState(false)
  const [inviteSaving, setInviteSaving] = useState(false)
  const [savingUserIds, setSavingUserIds] = useState<Set<number>>(() => new Set())
  const [resendingUserIds, setResendingUserIds] = useState<Set<number>>(() => new Set())
  const [roleMatrixOpen, setRoleMatrixOpen] = useState(false)
  const [programCreateDirty, setProgramCreateDirty] = useState(false)
  const [programCreating, setProgramCreating] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const selectedCohortIdRef = useRef<number | null | undefined>(undefined)
  const activeCoachWorkspaceIdRef = useRef(activeCoachWorkspaceId)
  const adminLoadSequenceRef = useRef(0)
  const serverUsersRef = useRef<AdminUser[]>([])
  const serverSelectedCohortRef = useRef<AdminCohort | null>(null)

  useLayoutEffect(() => {
    activeCoachWorkspaceIdRef.current = activeCoachWorkspaceId
    adminLoadSequenceRef.current += 1
  }, [activeCoachWorkspaceId])

  const displayCohorts = useMemo(() => cohorts.map((cohort) => cohortWithUserStats(cohort, users)), [cohorts, users])

  const selectedCohort = useMemo(
    () => displayCohorts.find((cohort) => cohort.id === selectedCohortId) ?? null,
    [displayCohorts, selectedCohortId],
  )

  const scopedUsers = useMemo(() => {
    if (!selectedCohortId) return users

    return users.filter((user) => user.cohorts.some((membership) => membership.cohort.id === selectedCohortId))
  }, [selectedCohortId, users])

  const matchingUsers = useMemo(
    () => filterAndSortAdminUsers(scopedUsers, {
      search: userSearch,
      status: userStatusFilter,
      role: userRoleFilter,
      sort: userSort,
    }),
    [scopedUsers, userRoleFilter, userSearch, userSort, userStatusFilter],
  )

  const rosterPages = Math.ceil(matchingUsers.length / 15)
  const currentRosterPage = Math.min(rosterPage, Math.max(0, rosterPages - 1))
  const visibleUsers = matchingUsers.slice(currentRosterPage * 15, (currentRosterPage + 1) * 15)

  const activeScopedUserCount = useMemo(() => scopedUsers.filter((user) => user.invitation_status !== 'revoked').length, [scopedUsers])

  const adminDraftsDirty = useMemo(() => {
    const emptyCreateDraft = { name: '', status: 'enrolling', starts_on: '', ends_on: '', notes: '' } satisfies AdminCohortInput
    if (JSON.stringify(cleanCohortDraft(createDraft)) !== JSON.stringify(emptyCreateDraft)) return true
    if (selectedCohort && editDraft && JSON.stringify(cleanCohortDraft(editDraft)) !== JSON.stringify(cleanCohortDraft(cohortDraftFor(selectedCohort)!))) return true

    const expectedInviteCohortId = selectedCohortId ? String(selectedCohortId) : ''
    if (inviteDraft.email?.trim() || (inviteDraft.role ?? 'participant') !== 'participant' ||
        String(inviteDraft.cohort_id ?? '') !== expectedInviteCohortId || inviteDraft.send_invitation_email === false) return true

    return users.some((user) => !adminUserDraftsEqual(userDrafts[user.id], adminDraftForUser(user)))
  }, [createDraft, editDraft, inviteDraft, selectedCohort, selectedCohortId, userDrafts, users])

  const adminMutationPending = loading || cohortSaving || programCreating || inviteSaving || savingUserIds.size > 0 || resendingUserIds.size > 0

  const adminStats = useMemo(() => ({
    cohorts: cohorts.length,
    users: users.length,
    pending: users.filter((user) => user.invitation_status === 'pending').length,
    setupComplete: users.filter((user) => user.workspace.setup_complete).length,
  }), [cohorts.length, users])

  const loadAdminData = useCallback(async (preferredCohortId?: number | null, reset?: { all?: boolean; userIds?: number[]; cohort?: boolean }) => {
    const sequence = ++adminLoadSequenceRef.current
    const requestedWorkspaceId = activeCoachWorkspaceIdRef.current
    setLoading(true)
    setError(null)
    try {
      const [nextCohorts, nextUsers, plaidHealthResult] = await Promise.all([
        fetchAdminCohorts(),
        fetchAdminUsers(),
        fetchAdminPlaidHealth()
          .then((value) => ({ value, error: null }))
          .catch(() => ({
            value: { summary: { connected: 0, healthy: 0, attention_required: 0 }, items: [] } satisfies AdminPlaidHealth,
            error: 'Bank connection health is temporarily unavailable. Cohorts and invitations are still available.',
          })),
      ])
      if (sequence !== adminLoadSequenceRef.current || requestedWorkspaceId !== activeCoachWorkspaceIdRef.current) return
      const requestedCohortId = preferredCohortId === undefined ? selectedCohortIdRef.current : preferredCohortId
      const nextSelectedId = requestedCohortId === null
        ? null
        : requestedCohortId && nextCohorts.some((cohort) => cohort.id === requestedCohortId)
          ? requestedCohortId
          : nextCohorts[0]?.id ?? null
      const nextSelectedCohort = nextCohorts.find((cohort) => cohort.id === nextSelectedId) ?? null

      selectedCohortIdRef.current = nextSelectedId
      setCohorts(nextCohorts)
      setUsers(nextUsers)
      setPlaidHealth(plaidHealthResult.value)
      setPlaidHealthError(plaidHealthResult.error)
      const previousUserDrafts = adminDraftsForUsers(serverUsersRef.current)
      const previousCohort = serverSelectedCohortRef.current
      serverUsersRef.current = nextUsers
      serverSelectedCohortRef.current = nextSelectedCohort
      setUserDrafts((current) => Object.fromEntries(nextUsers.map((user) => [user.id,
        !reset?.all && !reset?.userIds?.includes(user.id) && current[user.id] &&
          !adminUserDraftsEqual(current[user.id], previousUserDrafts[user.id])
          ? current[user.id] : adminDraftForUser(user),
      ])))
      setSelectedCohortId(nextSelectedId)
      setEditDraft((current) => !reset?.all && !reset?.cohort && current &&
        previousCohort?.id === nextSelectedId &&
        JSON.stringify(cleanCohortDraft(current)) !== JSON.stringify(cleanCohortDraft(cohortDraftFor(previousCohort)!))
        ? current : cohortDraftFor(nextSelectedCohort))
      setInviteDraft((current) => ({
        ...current,
        cohort_id: current.cohort_id || (nextSelectedId ? String(nextSelectedId) : ''),
      }))
    } catch (caught) {
      if (sequence === adminLoadSequenceRef.current && requestedWorkspaceId === activeCoachWorkspaceIdRef.current) {
        setError(caught instanceof Error ? caught.message : 'Admin data could not be loaded.')
      }
    } finally {
      if (sequence === adminLoadSequenceRef.current && requestedWorkspaceId === activeCoachWorkspaceIdRef.current) setLoading(false)
    }
  }, [])

  useEffect(() => {
    let cancelled = false

    queueMicrotask(() => {
      if (!cancelled) void loadAdminData()
    })

    return () => {
      cancelled = true
    }
  }, [activeCoachWorkspaceId, loadAdminData])

  function selectCohort(cohortId: number | null) {
    if (adminMutationPending || (adminDraftsDirty && !window.confirm('Discard unsaved cohort, invitation and participant changes?'))) return
    setUserDrafts(adminDraftsForUsers(users))
    selectedCohortIdRef.current = cohortId
    setRosterPage(0)
    setSelectedCohortId(cohortId)
    const nextCohort = cohorts.find((cohort) => cohort.id === cohortId) ?? null
    serverSelectedCohortRef.current = nextCohort
    setEditDraft(cohortDraftFor(nextCohort))
    setNotice(null)
    setInviteDraft((current) => ({ ...current, cohort_id: cohortId ? String(cohortId) : '' }))
  }

  function chooseAdminWorkspace(nextWorkspaceId: number | null) {
    if (nextWorkspaceId === activeCoachWorkspaceId || adminMutationPending) return
    if ((adminDraftsDirty || programCreateDirty) && !window.confirm('Discard unsaved program, cohort, invite, and user changes and switch workspaces?')) return

    setCreateDraft({ name: '', status: 'enrolling', starts_on: '', ends_on: '', notes: '' })
    setEditDraft(null)
    setInviteDraft({ email: '', role: 'participant', cohort_id: '', send_invitation_email: true })
    setUserDrafts({})
    setSelectedCohortId(null)
    selectedCohortIdRef.current = null
    setError(null)
    setNotice(null)
    selectCoachWorkspace(nextWorkspaceId)
  }

  async function handleCreateCohort(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (adminMutationPending) return
    if (platformMode) {
      setError('Choose a coach workspace before creating a cohort.')
      return
    }
    if (!createDraft.name.trim()) {
      setError('Cohort name is required.')
      return
    }

    setCohortSaving(true)
    setError(null)
    setNotice(null)
    try {
      const preserveCohortEdit = Boolean(selectedCohort && editDraft &&
        JSON.stringify(cleanCohortDraft(editDraft)) !== JSON.stringify(cleanCohortDraft(cohortDraftFor(selectedCohort)!)))
      const cohort = await createAdminCohort(cleanCohortDraft(createDraft))
      setNotice(`${cohort.name} is ready for invites.`)
      setCreateDraft({ name: '', status: 'enrolling', starts_on: '', ends_on: '', notes: '' })
      await loadAdminData(preserveCohortEdit ? undefined : cohort.id)
      if (!preserveCohortEdit) setInviteDraft((current) => ({ ...current, cohort_id: String(cohort.id) }))
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Cohort could not be created.')
    } finally {
      setCohortSaving(false)
    }
  }

  async function handleUpdateCohort(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (adminMutationPending) return
    if (!selectedCohort || !editDraft) return

    setCohortSaving(true)
    setError(null)
    setNotice(null)
    try {
      const cohort = await updateAdminCohort(selectedCohort.id, cleanCohortDraft(editDraft))
      setNotice(`${cohort.name} settings saved.`)
      await loadAdminData(cohort.id, { cohort: true })
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Cohort could not be saved.')
    } finally {
      setCohortSaving(false)
    }
  }

  async function handleInviteUser(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (adminMutationPending) return
    const inviteRole = inviteDraft.role ?? 'participant'
    const cohortId = String(inviteDraft.cohort_id ?? '')

    if (!inviteDraft.email?.trim()) {
      setError('Email is required before creating an invite.')
      return
    }
    if (roleRequiresCohort(inviteRole) && !cohortId) {
      setError(`${titleize(inviteRole)} users must be assigned to at least one cohort.`)
      return
    }

    setInviteSaving(true)
    setError(null)
    setNotice(null)
    try {
      const response = await createAdminUser({
        email: inviteDraft.email.trim(),
        role: inviteRole,
        cohort_id: cohortId || undefined,
        send_invitation_email: inviteDraft.send_invitation_email ?? true,
      })
      setNotice(`${response.user.email} ${inviteActionNotice(response)}${cohortId ? ' and assigned to the selected cohort' : ' as an admin'}. ${inviteDeliveryNotice(response)}`)
      setInviteDraft({ email: '', role: 'participant', cohort_id: selectedCohortId ? String(selectedCohortId) : '', send_invitation_email: true })
      await loadAdminData()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Invite could not be created.')
    } finally {
      setInviteSaving(false)
    }
  }

  async function handleSaveUser(user: AdminUser) {
    const draft = userDrafts[user.id]
    if (!draft || adminMutationPending) return
    if (cohortRequiredFor(draft.role, draft.invitation_status) && draft.cohort_ids.length === 0) {
      setError(`${titleize(draft.role)} users must be assigned to at least one cohort before saving unless access is revoked.`)
      return
    }

    markUserSaving(user.id, true)
    setError(null)
    setNotice(null)
    try {
      const updatedUser = await updateAdminUser(user.id, {
        role: draft.role,
        invitation_status: draft.invitation_status,
        cohort_ids: draft.cohort_ids.map(Number),
      })
      setNotice(`${updatedUser.email} was updated.`)
      await loadAdminData(undefined, { userIds: [user.id] })
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'User could not be saved.')
    } finally {
      markUserSaving(user.id, false)
    }
  }

  async function handleResendInvitation(user: AdminUser) {
    if (adminMutationPending) return

    markUserResending(user.id, true)
    setError(null)
    setNotice(null)
    try {
      const response = await resendAdminUserInvitation(user.id)
      setNotice(`${response.user.email} invitation refreshed. ${inviteDeliveryNotice(response)}`)
      await loadAdminData()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Invitation email could not be resent.')
    } finally {
      markUserResending(user.id, false)
    }
  }

  async function handleCancelInvite(user: AdminUser) {
    if (adminMutationPending || !window.confirm(`Cancel ${user.email}'s invitation and revoke their cohort access?`)) return

    markUserSaving(user.id, true)
    setError(null)
    setNotice(null)
    try {
      const updatedUser = await updateAdminUser(user.id, {
        invitation_status: 'revoked',
        cohort_ids: [],
      })
      setNotice(`${updatedUser.email} invite was cancelled and removed from cohorts.`)
      await loadAdminData(undefined, { userIds: [user.id] })
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Invite could not be cancelled.')
    } finally {
      markUserSaving(user.id, false)
    }
  }

  async function handleRemoveFromSelectedCohort(user: AdminUser) {
    if (!selectedCohortId || adminMutationPending || !window.confirm(`Remove ${user.email} from ${selectedCohort?.name ?? 'this cohort'}? If no required cohorts remain, their access will be revoked.`)) return
    const selectedId = String(selectedCohortId)
    const nextCohortIds = serverCohortIdsForUser(user).filter((cohortId) => cohortId !== selectedId)
    const shouldRevokeAfterRemoval = cohortRequiredFor(user.role, user.invitation_status) && nextCohortIds.length === 0
    const mutation: AdminUserInput = { cohort_ids: nextCohortIds.map(Number) }
    if (shouldRevokeAfterRemoval) mutation.invitation_status = 'revoked'

    markUserSaving(user.id, true)
    setError(null)
    setNotice(null)
    try {
      const updatedUser = await updateAdminUser(user.id, mutation)
      const cohortName = selectedCohort?.name ?? 'this cohort'
      setNotice(shouldRevokeAfterRemoval
        ? `${updatedUser.email} was removed from ${cohortName} and access was revoked because no cohorts remain.`
        : `${updatedUser.email} was removed from ${cohortName}.`)
      await loadAdminData(selectedCohortId, { userIds: [user.id] })
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'User could not be removed from this cohort.')
    } finally {
      markUserSaving(user.id, false)
    }
  }

  function markUserSaving(userId: number, saving: boolean) {
    setSavingUserIds((current) => toggleIdInSet(current, userId, saving))
  }

  function markUserResending(userId: number, resending: boolean) {
    setResendingUserIds((current) => toggleIdInSet(current, userId, resending))
  }

  function updateUserDraft(userId: number, key: 'role' | 'invitation_status', value: string) {
    setUserDrafts((current) => {
      const nextDraft = { ...current[userId] }
      if (key === 'role') nextDraft.role = value as UserRole
      if (key === 'invitation_status') nextDraft.invitation_status = value as InvitationStatus

      return {
        ...current,
        [userId]: nextDraft,
      }
    })
  }

  function toggleUserCohort(userId: number, cohortId: number) {
    const cohortIdValue = String(cohortId)
    setUserDrafts((current) => {
      const nextDraft = { ...current[userId] }
      const currentCohortIds = nextDraft.cohort_ids ?? []
      nextDraft.cohort_ids = currentCohortIds.includes(cohortIdValue)
        ? currentCohortIds.filter((id) => id !== cohortIdValue)
        : [...currentCohortIds, cohortIdValue]

      return {
        ...current,
        [userId]: nextDraft,
      }
    })
  }

  const inviteRole = inviteDraft.role ?? 'participant'
  const inviteRequiresCohort = roleRequiresCohort(inviteRole)

  return (
    <section className="screen-grid admin-screen">
      <header className="screen-heading admin-heading"><div><p className="eyebrow">Administration</p><h2 data-page-heading tabIndex={-1}>Program operations</h2><p>Manage participants, cohort access and support in the selected workspace.</p></div></header>

      {currentUser.is_admin && coachWorkspaces.length > 0 && (
        <label className="coach-workspace-picker">
          <span>Admin workspace</span>
          <select
            value={activeCoachWorkspaceId ?? 'platform'}
            disabled={adminMutationPending}
            onChange={(event) => chooseAdminWorkspace(event.target.value === 'platform' ? null : Number(event.target.value))}
          >
            <option value="platform">All workspaces / Platform</option>
            {coachWorkspaces.map((workspace) => <option key={workspace.id} value={workspace.id}>{workspace.name}</option>)}
          </select>
          <small>{platformMode ? 'Global review mode. Choose a workspace to create cohorts.' : 'Cohorts and invitations are scoped to this workspace.'}</small>
        </label>
      )}

      {error && <p className="admin-alert error" role="alert">{error}</p>}
      {notice && <p className="admin-alert success" role="status">{notice}</p>}

      <nav className="admin-area-nav" aria-label="Administration areas">
        {(['participants', 'cohorts', 'feedback', 'programs', 'health'] as const).map((value) => <button type="button" key={value} aria-pressed={area === value} disabled={adminMutationPending} onClick={() => setArea(value)}>{({ participants: 'Participants & access', cohorts: 'Cohorts', feedback: 'Support inbox', programs: 'Programs & rules', health: 'Bank health' })[value]}</button>)}
      </nav>
      <label className="admin-current-cohort">Cohort scope<select disabled={adminMutationPending} value={selectedCohortId ?? ''} onChange={(event) => selectCohort(event.target.value ? Number(event.target.value) : null)}><option value="">All users</option>{displayCohorts.map((cohort) => <option key={cohort.id} value={cohort.id}>{cohort.name}</option>)}</select></label>

      <div hidden={area !== 'programs'}>
      {currentUser.is_admin && <CreateCoachProgram key={activeCoachWorkspaceId ?? 'platform'} disabled={adminMutationPending || adminDraftsDirty} onDirtyChange={setProgramCreateDirty} onPendingChange={setProgramCreating} />}

      <RoleMatrix open={roleMatrixOpen} onToggle={setRoleMatrixOpen} />
      </div>
      <div className="admin-stat-row">
        <AdminStat label="Cohorts" value={adminStats.cohorts.toString()} />
        <AdminStat label="Invited users" value={adminStats.users.toString()} />
        <AdminStat label="Pending" value={adminStats.pending.toString()} />
        <AdminStat label="Optional setup complete" value={adminStats.setupComplete.toString()} />
      </div>

      <div hidden={area !== 'health'}><PlaidHealthLedger health={plaidHealth} loading={loading} error={plaidHealthError} /></div>
      <div hidden={area !== 'feedback'}><PilotFeedbackInbox /></div>

      <div hidden={area !== 'cohorts' && area !== 'participants'} className="admin-layout">
        <article hidden={area !== 'cohorts'} className="panel admin-card">
          <div className="admin-card-heading">
            <span className="spark" aria-hidden="true"><CohortIcon /></span>
            <div>
              <p className="eyebrow">Cohorts</p>
              <h3>Create the next group</h3>
            </div>
          </div>

          <form className="admin-form" onSubmit={handleCreateCohort}>
            <label className="admin-field wide">
              <span>Cohort name</span>
              <input value={createDraft.name} onChange={(event) => setCreateDraft((current) => ({ ...current, name: event.target.value }))} placeholder="Tuesday pilot cohort" />
            </label>
            <label className="admin-field">
              <span>Status</span>
              <select value={createDraft.status} onChange={(event) => setCreateDraft((current) => ({ ...current, status: event.target.value as AdminCohortStatus }))}>
                {cohortStatuses.map((status) => <option key={status} value={status}>{titleize(status)}</option>)}
              </select>
            </label>
            <label className="admin-field">
              <span>Starts</span>
              <input type="date" value={createDraft.starts_on ?? ''} onChange={(event) => setCreateDraft((current) => ({ ...current, starts_on: event.target.value }))} />
            </label>
            <label className="admin-field">
              <span>Ends</span>
              <input type="date" value={createDraft.ends_on ?? ''} onChange={(event) => setCreateDraft((current) => ({ ...current, ends_on: event.target.value }))} />
            </label>
            <label className="admin-field wide">
              <span>Notes</span>
              <textarea value={createDraft.notes ?? ''} onChange={(event) => setCreateDraft((current) => ({ ...current, notes: event.target.value }))} placeholder="Pilot focus, meeting cadence, or setup notes" rows={3} />
            </label>
            <button type="submit" disabled={adminMutationPending || platformMode}>{cohortSaving ? 'Saving' : 'Create cohort'}</button>
            {platformMode && <p className="admin-muted">Choose an Admin workspace above before creating a cohort.</p>}
          </form>
        </article>

        <article hidden={area !== 'cohorts'} className="panel admin-card">
          <div className="admin-card-heading">
            <span className="spark" aria-hidden="true"><UsersIcon /></span>
            <div>
              <p className="eyebrow">Cohort list</p>
              <h3>Select a group to manage</h3>
            </div>
          </div>

          {loading && cohorts.length === 0 ? (
            <p className="admin-muted">Loading cohorts and invitations...</p>
          ) : (
            <div className="cohort-list">
              <button type="button" className={`cohort-list-card ${selectedCohortId === null ? 'active' : ''}`} onClick={() => selectCohort(null)}>
                <strong>All users</strong>
                <span>Full invitation list</span>
              </button>
              {displayCohorts.map((cohort) => (
                <button type="button" className={`cohort-list-card ${selectedCohortId === cohort.id ? 'active' : ''}`} key={cohort.id} onClick={() => selectCohort(cohort.id)}>
                  <strong>{cohort.name}</strong>
                  <span>{titleize(cohort.status)} · {cohort.member_count} users · {cohort.setup_complete_count} optional setups complete</span>
                </button>
              ))}
            </div>
          )}
        </article>
      </div>

      <div hidden={area !== 'cohorts' && area !== 'participants'} className="admin-layout">
        <article hidden={area !== 'cohorts'} className="panel admin-card">
          <div className="admin-card-heading">
            <span className="spark" aria-hidden="true"><CohortIcon /></span>
            <div>
              <p className="eyebrow">Selected cohort</p>
              <h3>{selectedCohort ? selectedCohort.name : 'No cohort selected'}</h3>
            </div>
          </div>

          {selectedCohort && editDraft ? (
            <form className="admin-form" onSubmit={handleUpdateCohort}>
              <div className="admin-cohort-summary">
                <AdminBadge value={titleize(selectedCohort.status)} tone={selectedCohort.status === 'active' ? 'green' : selectedCohort.status === 'archived' ? 'red' : 'gold'} />
                <span>{selectedCohort.participant_count} participants</span>
                <span>{selectedCohort.staff_count} staff</span>
                <span>{cohortDateRange(selectedCohort)}</span>
              </div>
              <div className="admin-operations" aria-label="Privacy-safe cohort operations for the last seven days">
                {selectedCohort.operational_summary.available ? (
                  <>
                    <div><small>Active participants</small><strong>{selectedCohort.operational_summary.participants_active}</strong></div>
                    <div><small>Mia requests</small><strong>{selectedCohort.operational_summary.mia_requests}</strong></div>
                    <div><small>Typical Mia time</small><strong>{selectedCohort.operational_summary.average_mia_latency_ms === null ? '—' : `${(selectedCohort.operational_summary.average_mia_latency_ms / 1000).toFixed(1)}s`}</strong></div>
                    <div><small>Mia failures</small><strong>{selectedCohort.operational_summary.mia_failures}</strong></div>
                    <div><small>Uploads</small><strong>{selectedCohort.operational_summary.uploads}</strong></div>
                    <div><small>Upload failures</small><strong>{selectedCohort.operational_summary.upload_failures}</strong></div>
                  </>
                ) : (
                  <p role="status">Activity metrics are temporarily unavailable. Refresh before using this cohort summary to judge participation.</p>
                )}
              </div>
              <p className="admin-privacy-copy">Last 7 days · aggregate operational activity only. Financial values, uploaded document contents, and Mia conversations are not shown.</p>
              <label className="admin-field wide">
                <span>Name</span>
                <input disabled={adminMutationPending} value={editDraft.name} onChange={(event) => setEditDraft((current) => current ? { ...current, name: event.target.value } : current)} />
              </label>
              <label className="admin-field">
                <span>Status</span>
                <select disabled={adminMutationPending} value={editDraft.status} onChange={(event) => setEditDraft((current) => current ? { ...current, status: event.target.value as AdminCohortStatus } : current)}>
                  {cohortStatuses.map((status) => <option key={status} value={status}>{titleize(status)}</option>)}
                </select>
              </label>
              <label className="admin-field">
                <span>Starts</span>
                <input disabled={adminMutationPending} type="date" value={editDraft.starts_on ?? ''} onChange={(event) => setEditDraft((current) => current ? { ...current, starts_on: event.target.value } : current)} />
              </label>
              <label className="admin-field">
                <span>Ends</span>
                <input disabled={adminMutationPending} type="date" value={editDraft.ends_on ?? ''} onChange={(event) => setEditDraft((current) => current ? { ...current, ends_on: event.target.value } : current)} />
              </label>
              <label className="admin-field wide">
                <span>Notes</span>
                <textarea disabled={adminMutationPending} value={editDraft.notes ?? ''} onChange={(event) => setEditDraft((current) => current ? { ...current, notes: event.target.value } : current)} rows={3} />
              </label>
              <button type="submit" disabled={adminMutationPending}>{cohortSaving ? 'Saving' : 'Save cohort'}</button>
            </form>
          ) : (
            <p className="admin-muted">Create a cohort, then select it here to update dates, status, and notes.</p>
          )}
        </article>

        <details hidden={area !== 'participants'} className="panel admin-card admin-invite-disclosure"><summary>Invite a participant or staff member</summary>
          <div className="admin-card-heading">
            <span className="spark" aria-hidden="true"><ShieldIcon /></span>
            <div>
              <p className="eyebrow">Invite user</p>
              <h3>Add admin, coach, or participant</h3>
            </div>
          </div>

          <form className="admin-form" onSubmit={handleInviteUser}>
            <label className="admin-field wide">
              <span>Email</span>
              <input type="email" value={inviteDraft.email ?? ''} onChange={(event) => setInviteDraft((current) => ({ ...current, email: event.target.value }))} placeholder="name@example.com" />
            </label>
            <label className="admin-field">
              <span>Role</span>
              <select value={inviteRole} onChange={(event) => setInviteDraft((current) => ({ ...current, role: event.target.value as UserRole }))}>
                {userRoles.map((role) => <option key={role} value={role}>{titleize(role)}</option>)}
              </select>
            </label>
            <label className="admin-field">
              <span>Cohort {inviteRequiresCohort ? '(required)' : '(optional)'}</span>
              <select required={inviteRequiresCohort} value={String(inviteDraft.cohort_id ?? '')} onChange={(event) => setInviteDraft((current) => ({ ...current, cohort_id: event.target.value }))}>
                <option value="">{inviteRequiresCohort ? 'Select a cohort' : 'No cohort for admin'}</option>
                {cohorts.map((cohort) => <option key={cohort.id} value={cohort.id}>{cohort.name}</option>)}
              </select>
            </label>
            <label className="admin-inline-check wide">
              <input
                type="checkbox"
                checked={inviteDraft.send_invitation_email ?? true}
                onChange={(event) => setInviteDraft((current) => ({ ...current, send_invitation_email: event.target.checked }))}
              />
              <span>Send invite email now</span>
            </label>
            <p className="admin-field-note wide">Names come from the invited person's Clerk account after first sign-in. Admins can manage across cohorts without assignment; active coaches and participants must belong to at least one cohort.</p>
            <button type="submit" disabled={adminMutationPending}>{inviteSaving ? 'Creating invite' : 'Create invite'}</button>
          </form>
        </details>
      </div>

      <article hidden={area !== 'participants'} className="panel admin-card admin-users-panel">
        <div className="admin-card-heading row-between">
          <div>
            <p className="eyebrow">Users</p>
            <h3>{selectedCohort ? `${selectedCohort.name} members` : 'All invited users'}</h3>
            <p className="admin-list-summary">Showing {visibleUsers.length} of {matchingUsers.length} matching users · {scopedUsers.length} in this cohort scope. Revoked users are hidden by default.</p>
          </div>
          <button type="button" className="admin-refresh" onClick={() => { if (adminDraftsDirty && !window.confirm('Discard unsaved changes and refresh?')) return; void loadAdminData(undefined, { all: true }) }} disabled={adminMutationPending}>{loading ? 'Refreshing' : 'Refresh'}</button>
        </div>

        <div className="admin-user-toolbar" aria-label="User filters and sorting">
          <label className="admin-field compact search-field">
            <span>Search</span>
            <input value={userSearch} onChange={(event) => { setUserSearch(event.target.value); setRosterPage(0) }} placeholder="Name or email" />
          </label>
          <label className="admin-field compact">
            <span>Status</span>
            <select value={userStatusFilter} onChange={(event) => { setUserStatusFilter(event.target.value as UserStatusFilter); setRosterPage(0) }}>
              <option value="active">Active only ({activeScopedUserCount})</option>
              <option value="pending">Pending</option>
              <option value="accepted">Accepted</option>
              <option value="revoked">Revoked</option>
              <option value="all">All statuses</option>
            </select>
          </label>
          <label className="admin-field compact">
            <span>Role</span>
            <select value={userRoleFilter} onChange={(event) => { setUserRoleFilter(event.target.value as UserRoleFilter); setRosterPage(0) }}>
              <option value="all">All roles</option>
              {userRoles.map((role) => <option key={role} value={role}>{titleize(role)}</option>)}
            </select>
          </label>
          <label className="admin-field compact">
            <span>Sort</span>
            <select value={userSort} onChange={(event) => { setUserSort(event.target.value as UserSortKey); setRosterPage(0) }}>
              <option value="name_asc">Name A–Z</option>
              <option value="email_asc">Email A–Z</option>
              <option value="role_asc">Role</option>
              <option value="status_asc">Status</option>
              <option value="setup_desc">Optional setup progress</option>
              <option value="invite_desc">Recent invite activity</option>
            </select>
          </label>
        </div>

        {visibleUsers.length === 0 ? (
          <p className="admin-muted">{scopedUsers.length === 0 ? 'No users in this view yet. Create an invite above to start the cohort.' : 'No users match these filters. Switch status to Revoked or All statuses when you need to review cancelled access.'}</p>
        ) : (
          <div className="admin-user-list">
            {visibleUsers.map((user) => {
              const draft = userDrafts[user.id] ?? adminDraftForUser(user)
              const isSelf = user.id === currentUser.id

              const draftNeedsCohort = cohortRequiredFor(draft.role, draft.invitation_status) && draft.cohort_ids.length === 0
              const draftRequiresCohort = cohortRequiredFor(draft.role, draft.invitation_status)
              const canResendInvite = user.invitation_status === 'pending'
              const canCancelInvite = user.invitation_status === 'pending' && !isSelf
              const canRemoveFromSelectedCohort = selectedCohortId !== null && serverCohortIdsForUser(user).includes(String(selectedCohortId)) && !isSelf
              const rowSaving = savingUserIds.has(user.id)
              const rowResending = resendingUserIds.has(user.id)

              return (
                <details name="admin-participant-access" className="admin-user-row" key={`${activeCoachWorkspaceId ?? 'platform'}:${user.id}`}>
                  <summary className="admin-user-summary"><span><strong>{user.full_name || user.email}</strong><small>{user.email}</small></span><span className="admin-badge-row"><AdminBadge value={titleize(user.role)} tone="neutral" /><AdminBadge value={titleize(user.invitation_status)} tone={user.invitation_status === 'accepted' ? 'green' : user.invitation_status === 'revoked' ? 'red' : 'gold'} /></span><span>{adminUserDraftsEqual(draft, adminDraftForUser(user)) ? 'View & manage access' : 'Unsaved access changes'}</span></summary>
                  <div className="admin-user-detail"><div className="admin-user-main">
                    <div>
                      <strong>{user.full_name}</strong>
                      <span>{user.email}</span>
                    </div>
                    <div className="admin-badge-row">
                      <AdminBadge value={titleize(user.role)} tone={user.role === 'admin' ? 'green' : user.role === 'coach' ? 'gold' : 'neutral'} />
                      <AdminBadge value={titleize(user.invitation_status)} tone={user.invitation_status === 'accepted' ? 'green' : user.invitation_status === 'revoked' ? 'red' : 'gold'} />
                      {user.invite_email.workspace_scoped
                        ? <AdminBadge value="Email details in Platform mode" tone="neutral" />
                        : <AdminBadge value={`Email ${titleize(user.invite_email.status)}`} tone={inviteEmailTone(user.invite_email.status)} />}
                      <AdminBadge value={`Optional household setup: ${pilotSetupLabel(user.workspace.setup_status)}`} tone={user.workspace.setup_complete ? 'green' : user.workspace.setup_status === 'started' ? 'gold' : 'neutral'} />
                      <AdminBadge value={user.workspace.signed_in ? 'Signed in' : 'Not signed in'} tone={user.workspace.signed_in ? 'green' : 'neutral'} />
                      {user.workspace.has_pending_review_work && <AdminBadge value="Review waiting" tone="gold" />}
                    </div>
                    <p>{user.cohorts.map((membership) => membership.cohort.name).join(', ') || (user.role === 'admin' ? 'No cohort assigned; admin can work across cohorts' : 'No cohort assigned yet')}</p>
                    {user.invite_email.last_attempted_at && (
                      <p className="admin-email-line">Last email attempt: {shortDateTime(user.invite_email.last_attempted_at)}{user.invite_email.error ? ` · ${user.invite_email.error}` : ''}</p>
                    )}
                    <p className="admin-email-line">Last safe activity: {user.workspace.last_safe_activity_at ? shortDateTime(user.workspace.last_safe_activity_at) : 'No participant activity yet'}</p>
                  </div>

                  <div className="admin-user-controls">
                    <label className="admin-field compact">
                      <span>Role</span>
                      <select value={draft.role} disabled={isSelf || adminMutationPending} onChange={(event) => updateUserDraft(user.id, 'role', event.target.value)}>
                        {userRoles.map((role) => <option key={role} value={role}>{titleize(role)}</option>)}
                      </select>
                    </label>
                    <label className="admin-field compact">
                      <span>Status</span>
                      <select value={draft.invitation_status} disabled={isSelf || adminMutationPending} onChange={(event) => updateUserDraft(user.id, 'invitation_status', event.target.value)}>
                        {invitationStatuses.map((status) => <option key={status} value={status}>{titleize(status)}</option>)}
                      </select>
                    </label>
                    <div className={`admin-field compact cohort-select ${draftNeedsCohort ? 'needs-attention' : ''}`}>
                      <span>Cohorts {draftRequiresCohort ? '(required)' : '(optional)'}</span>
                      <div className="admin-cohort-checks">
                        {cohorts.length === 0 && <small>No cohorts yet. Create one before adding coaches or participants.</small>}
                        {cohorts.map((cohort) => (
                          <label className="admin-cohort-check" key={cohort.id}>
                            <input
                              type="checkbox"
                              disabled={adminMutationPending}
                              checked={draft.cohort_ids.includes(String(cohort.id))}
                              onChange={() => toggleUserCohort(user.id, cohort.id)}
                            />
                            <span>{cohort.name}</span>
                          </label>
                        ))}
                      </div>
                      {draftNeedsCohort && <small className="admin-field-warning">Required before saving.</small>}
                    </div>
                    <div className="admin-user-actions">
                      <button type="button" onClick={() => void handleSaveUser(user)} disabled={adminMutationPending || draftNeedsCohort}>{rowSaving ? 'Saving' : 'Save'}</button>
                      <button type="button" className="secondary-action" onClick={() => void handleResendInvitation(user)} disabled={adminMutationPending || !canResendInvite}>{rowResending ? 'Sending' : 'Resend email'}</button>
                      {canCancelInvite && <button type="button" className="danger-action" onClick={() => void handleCancelInvite(user)} disabled={adminMutationPending}>Cancel invite</button>}
                      {canRemoveFromSelectedCohort && <button type="button" className="danger-action" onClick={() => void handleRemoveFromSelectedCohort(user)} disabled={adminMutationPending}>Remove from cohort</button>}
                    </div>
                  </div></div>
                </details>
              )
            })}
          </div>
        )}
        {rosterPages > 1 && <div className="admin-roster-pages" aria-label="Participant pages"><button type="button" disabled={currentRosterPage === 0 || adminMutationPending} onClick={() => setRosterPage(currentRosterPage - 1)}>Previous participants</button><span>Page {currentRosterPage + 1} of {rosterPages}</span><button type="button" disabled={currentRosterPage + 1 >= rosterPages || adminMutationPending} onClick={() => setRosterPage(currentRosterPage + 1)}>Next participants</button></div>}
      </article>
    </section>
  )
}

function AdminStat({ label, value }: { label: string; value: string }) {
  return (
    <article className="metric-card admin-stat-card">
      <span>{label}</span>
      <strong>{value}</strong>
    </article>
  )
}

function PlaidHealthLedger({ health, loading, error }: { health: AdminPlaidHealth; loading: boolean; error: string | null }) {
  return (
    <article className="panel admin-card admin-plaid-health">
      <div className="admin-card-heading row-between">
        <div>
          <p className="eyebrow">Connection health</p>
          <h3>Bank feed ledger</h3>
          <p className="admin-list-summary">Operational metadata only—no balances, transactions, Plaid identifiers, or access credentials.</p>
        </div>
        <div className="admin-plaid-health-summary" aria-label="Plaid connection health summary">
          <span><strong>{health.summary.connected}</strong> connected</span>
          <span className="is-healthy"><strong>{health.summary.healthy}</strong> current</span>
          <span className={health.summary.attention_required > 0 ? 'is-attention' : ''}><strong>{health.summary.attention_required}</strong> attention</span>
        </div>
      </div>

      {error && <p className="admin-alert error" role="status">{error}</p>}

      {loading && health.items.length === 0 ? (
        <p className="admin-muted">Checking bank feed health...</p>
      ) : health.items.length === 0 ? (
        <p className="admin-muted">No active Plaid connections yet.</p>
      ) : (
        <div className="admin-plaid-health-list">
          {health.items.map((item) => (
            <article className={`admin-plaid-health-row is-${item.health.state}`} key={item.id}>
              <span className="admin-plaid-health-mark" aria-hidden="true" />
              <div>
                <strong>{item.institution_name}</strong>
                <span>{item.household.name} · {item.account_count} account{item.account_count === 1 ? '' : 's'} · {item.environment}</span>
                <small>Connected by {item.connected_by.full_name} · {item.connected_by.email}</small>
              </div>
              <div className="admin-plaid-health-state">
                <AdminBadge value={item.health.label} tone={plaidHealthTone(item.health.state)} />
                <small>{item.health.message}</small>
                <small>{item.health.last_successful_update_at ? `Last successful update ${new Date(item.health.last_successful_update_at).toLocaleString()}` : 'No successful update recorded yet.'}</small>
                {item.error_code && <small>Reference: {item.error_code}</small>}
              </div>
            </article>
          ))}
        </div>
      )}
    </article>
  )
}

function plaidHealthTone(state: AdminPlaidHealth['items'][number]['health']['state']): 'green' | 'gold' | 'red' | 'neutral' {
  if (state === 'healthy') return 'green'
  if (state === 'initializing' || state === 'disconnecting') return 'gold'
  if (state === 'stale' || state === 'action_required' || state === 'error') return 'red'

  return 'neutral'
}

function AdminBadge({ value, tone }: { value: string; tone: 'green' | 'gold' | 'red' | 'neutral' }) {
  return <span className={`admin-badge ${tone}`}>{value}</span>
}

function RoleMatrix({ open, onToggle }: { open: boolean; onToggle: (open: boolean) => void }) {
  return (
    <details className="role-matrix panel" open={open} onToggle={(event) => onToggle(event.currentTarget.open)}>
      <summary>
        <span>
          <strong>Role and cohort rules</strong>
          <small>Backend-enforced policy for admin, coach, and participant users.</small>
        </span>
      </summary>
      <div className="role-matrix-grid">
        <article>
          <strong>Admin</strong>
          <span>May have no cohort</span>
          <p>Can manage cohorts, users, invitations, and staff access. Admins are not limited to a single participant group.</p>
        </article>
        <article>
          <strong>Coach</strong>
          <span>Requires at least one active cohort</span>
          <p>Supports assigned groups and can create participant invites, but cannot manage admin or coach accounts. Revoked coaches can have no cohort.</p>
        </article>
        <article>
          <strong>Participant</strong>
          <span>Requires at least one active cohort</span>
          <p>Uses the household workspace and Mia coaching flow. Revoked participants can be removed from all cohorts.</p>
        </article>
      </div>
    </details>
  )
}

function adminDraftsForUsers(users: AdminUser[]) {
  return users.reduce<Record<number, AdminUserDraft>>((drafts, user) => {
    drafts[user.id] = adminDraftForUser(user)
    return drafts
  }, {})
}

function adminDraftForUser(user: AdminUser): AdminUserDraft {
  return {
    role: user.role,
    invitation_status: user.invitation_status,
    cohort_ids: serverCohortIdsForUser(user),
  }
}

function adminUserDraftsEqual(left: AdminUserDraft | undefined, right: AdminUserDraft) {
  if (!left) return true
  return left.role === right.role && left.invitation_status === right.invitation_status &&
    [...left.cohort_ids].sort().join(',') === [...right.cohort_ids].sort().join(',')
}

function serverCohortIdsForUser(user: AdminUser) {
  return user.cohorts.map((membership) => String(membership.cohort.id))
}

function roleRequiresCohort(role: UserRole) {
  return role !== 'admin'
}

function cohortRequiredFor(role: UserRole, invitationStatus: InvitationStatus) {
  return roleRequiresCohort(role) && invitationStatus !== 'revoked'
}

function toggleIdInSet(current: Set<number>, id: number, enabled: boolean) {
  const next = new Set(current)
  if (enabled) next.add(id)
  else next.delete(id)
  return next
}

function cohortWithUserStats(cohort: AdminCohort, users: AdminUser[]): AdminCohort {
  const memberships = users.flatMap((user) => user.cohorts
    .filter((membership) => membership.cohort.id === cohort.id)
    .map((membership) => ({ user, membership })))

  return {
    ...cohort,
    operational_summary: cohort.operational_summary ?? emptyCohortOperationalSummary,
    member_count: memberships.length,
    participant_count: memberships.filter(({ membership }) => membership.role === 'participant').length,
    staff_count: memberships.filter(({ membership }) => membership.role === 'admin' || membership.role === 'coach').length,
  }
}

function filterAndSortAdminUsers(users: AdminUser[], filters: { search: string; status: UserStatusFilter; role: UserRoleFilter; sort: UserSortKey }) {
  const search = filters.search.trim().toLowerCase()
  const filtered = users.filter((user) => {
    const statusMatches = filters.status === 'all'
      ? true
      : filters.status === 'active'
        ? user.invitation_status !== 'revoked'
        : user.invitation_status === filters.status
    const roleMatches = filters.role === 'all' || user.role === filters.role
    const searchMatches = !search || `${user.full_name} ${user.email}`.toLowerCase().includes(search)

    return statusMatches && roleMatches && searchMatches
  })

  return [...filtered].sort((left, right) => compareAdminUsers(left, right, filters.sort))
}

function compareAdminUsers(left: AdminUser, right: AdminUser, sort: UserSortKey) {
  if (sort === 'email_asc') return left.email.localeCompare(right.email)
  if (sort === 'role_asc') return compareTextThenName(left.role, right.role, left, right)
  if (sort === 'status_asc') return compareTextThenName(left.invitation_status, right.invitation_status, left, right)
  if (sort === 'setup_desc') return pilotSetupRank(right.workspace.setup_status) - pilotSetupRank(left.workspace.setup_status) || compareByName(left, right)
  if (sort === 'invite_desc') return sortableTime(right.invite_email.last_attempted_at) - sortableTime(left.invite_email.last_attempted_at) || compareByName(left, right)

  return compareByName(left, right)
}

function compareTextThenName(leftValue: string, rightValue: string, leftUser: AdminUser, rightUser: AdminUser) {
  return leftValue.localeCompare(rightValue) || compareByName(leftUser, rightUser)
}

function compareByName(left: AdminUser, right: AdminUser) {
  return left.full_name.localeCompare(right.full_name) || left.email.localeCompare(right.email)
}

function sortableTime(value: string | null) {
  return value ? new Date(value).getTime() : 0
}

function pilotSetupRank(status: AdminUser['workspace']['setup_status']) {
  if (status === 'complete') return 2
  if (status === 'started') return 1
  return 0
}

function pilotSetupLabel(status: AdminUser['workspace']['setup_status']) {
  if (status === 'complete') return 'Setup complete'
  if (status === 'started') return 'Setup started'
  return 'Setup not started'
}

function inviteActionNotice(response: AdminUserMutationResponse) {
  if (response.reactivated) return 'was reactivated'
  if (response.created === false) return 'was updated'

  return 'is invited'
}

function inviteDeliveryNotice(response: AdminUserMutationResponse) {
  if (response.invitation_sent) return 'Invite email sent through Resend.'
  if (response.invitation_status === 'failed') return `Invite saved, but email delivery failed${response.invitation_error ? `: ${response.invitation_error}` : '.'}`
  if (response.invitation_status === 'skipped') return 'Invite saved; email delivery was skipped by admin.'

  return 'Invite saved.'
}

function inviteEmailTone(status: AdminUser['invite_email']['status']): 'green' | 'gold' | 'red' | 'neutral' {
  if (status === 'sent') return 'green'
  if (status === 'failed') return 'red'
  if (status === 'skipped') return 'gold'

  return 'neutral'
}

function shortDateTime(value: string) {
  return new Intl.DateTimeFormat('en-US', {
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  }).format(new Date(value))
}

function cleanCohortDraft(draft: AdminCohortInput): AdminCohortInput {
  return {
    name: draft.name.trim(),
    status: draft.status,
    starts_on: draft.starts_on || '',
    ends_on: draft.ends_on || '',
    notes: draft.notes?.trim() ?? '',
  }
}

function cohortDraftFor(cohort: AdminCohort | null): AdminCohortInput | null {
  if (!cohort) return null

  return {
    name: cohort.name,
    status: cohort.status,
    starts_on: cohort.starts_on ?? '',
    ends_on: cohort.ends_on ?? '',
    notes: cohort.notes ?? '',
  }
}

function titleize(value: string) {
  return value.replace(/_/g, ' ').replace(/\b\w/g, (letter) => letter.toUpperCase())
}

function cohortDateRange(cohort: AdminCohort) {
  if (cohort.starts_on && cohort.ends_on) return `${formatShortDate(cohort.starts_on)} – ${formatShortDate(cohort.ends_on)}`
  if (cohort.starts_on) return `Starts ${formatShortDate(cohort.starts_on)}`
  if (cohort.ends_on) return `Ends ${formatShortDate(cohort.ends_on)}`

  return 'Dates not set'
}

function formatShortDate(value: string) {
  return new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(`${value}T00:00:00`))
}

function CohortIcon() {
  return (
    <svg viewBox="0 0 24 24" role="img" aria-label="Cohort">
      <path d="M4.5 6.5A2.5 2.5 0 0 1 7 4h10a2.5 2.5 0 0 1 2.5 2.5v11A2.5 2.5 0 0 1 17 20H7a2.5 2.5 0 0 1-2.5-2.5v-11Z" className="icon-stroke" />
      <path d="M8 9h8M8 12h5M8 15h7" className="icon-stroke" />
    </svg>
  )
}

function UsersIcon() {
  return (
    <svg viewBox="0 0 24 24" role="img" aria-label="Users">
      <path d="M9.2 11.1a3.1 3.1 0 1 0 0-6.2 3.1 3.1 0 0 0 0 6.2ZM4.4 19.1c.55-3.1 2.2-4.65 4.8-4.65 2.58 0 4.22 1.55 4.78 4.65" className="icon-stroke" />
      <path d="M16.2 11.4a2.55 2.55 0 1 0 0-5.1M15.7 14.45c2.05.18 3.35 1.58 3.9 4.2" className="icon-stroke" />
    </svg>
  )
}

function ShieldIcon() {
  return (
    <svg viewBox="0 0 24 24" role="img" aria-label="Secure access">
      <path d="M12 2.7 19 5.4v5.25c0 4.45-2.8 8.5-7 10.05-4.2-1.55-7-5.6-7-10.05V5.4l7-2.7Z" />
      <path d="m8.9 12.05 2 2 4.2-4.45" className="icon-stroke" />
    </svg>
  )
}
