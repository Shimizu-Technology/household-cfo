import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react'
import { ApiRequestError, type CurrentUser } from '../api'
import { useAuthContext } from '../contexts/authContextValue'
import { createEnterpriseGroupMapping, createEnterpriseOrganization, fetchEnterpriseMembers, fetchEnterpriseOrganization, fetchEnterpriseOrganizations, openEnterprisePortal, reconcileEnterpriseOrganization, updateEnterpriseGroupMapping, updateEnterpriseMember, updateEnterpriseOrganization, type EnterpriseDetail, type EnterpriseInput, type EnterpriseMember, type EnterpriseOrganizationOption } from '../enterpriseApi'
import { usePilotDialog } from '../lib/usePilotDialog'
import { Button } from './Button'
import './EnterpriseSettings.css'

// Organization access is an IT capability; it does not change the actor's finance role.
export function EnterpriseSettings({ currentUser, onClose }: { currentUser: CurrentUser; onClose: () => void }) {
  const dialog = usePilotDialog(onClose)
  const { signIn } = useAuthContext()
  const [organizations, setOrganizations] = useState<EnterpriseOrganizationOption[]>([])
  const [selectedId, setSelectedId] = useState<number | null>(null)
  const [detail, setDetail] = useState<EnterpriseDetail | null>(null)
  const [members, setMembers] = useState<EnterpriseMember[]>([])
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [organizationSignInRequired, setOrganizationSignInRequired] = useState(false)
  const [admissionReviewed, setAdmissionReviewed] = useState(false)
  const [newOrganization, setNewOrganization] = useState(false)
  const [name, setName] = useState('')
  const [workosId, setWorkosId] = useState('')
  const [workspaceId, setWorkspaceId] = useState('')
  const [groupId, setGroupId] = useState('')
  const [cohortId, setCohortId] = useState('')
  const [confirmation, setConfirmation] = useState<{ member: EnterpriseMember; itAdmin: boolean } | null>(null)
  const selectedIdRef = useRef<number | null>(null)
  const mounted = useRef(true)
  const sequence = useRef(0)
  const abort = useRef<AbortController | null>(null)
  const busyRef = useRef(false)

  const load = useCallback(async (id: number | null) => {
    abort.current?.abort()
    const controller = new AbortController(); abort.current = controller
    const request = ++sequence.current
    const current = () => mounted.current && request === sequence.current && !controller.signal.aborted
    setLoading(true); setError(null); setDetail(null); setMembers([]); setConfirmation(null); setOrganizationSignInRequired(false); setAdmissionReviewed(false)
    try {
      const result = await fetchEnterpriseOrganizations(controller.signal)
      if (!current()) return
      setOrganizations(result.enterprise_organizations)
      const target = result.enterprise_organizations.some(org => org.id === id) ? id : result.enterprise_organizations[0]?.id ?? null
      if (selectedIdRef.current !== target) { setGroupId(''); setCohortId('') }
      selectedIdRef.current = target
      setSelectedId(target)
      if (target !== null) {
        const [next, roster] = await Promise.all([fetchEnterpriseOrganization(target, controller.signal), fetchEnterpriseMembers(target, controller.signal)])
        if (!current()) return
        if (next.enterprise_organization.id !== target) throw new Error('The organization response could not be verified. Reload this screen.')
        setDetail(next); setMembers(roster.memberships)
      }
    } catch (caught) {
      if (current()) { setError(caught instanceof Error ? caught.message : 'Organization access could not be loaded.'); setOrganizationSignInRequired(caught instanceof ApiRequestError && caught.code === 'enterprise_organization_signin_required') }
    } finally { if (current()) setLoading(false) }
  }, [])

  useEffect(() => {
    mounted.current = true
    queueMicrotask(() => { if (mounted.current) void load(null) })
    return () => { mounted.current = false; sequence.current += 1; abort.current?.abort() }
  }, [load])

  async function run(operation: () => Promise<unknown>, message?: string) {
    if (busyRef.current || loading) return
    busyRef.current = true; setBusy(true); setError(null); setNotice(null)
    try {
      await operation()
      if (!mounted.current) return
      if (message) { setNotice(message); await load(selectedIdRef.current) }
    } catch (caught) {
      if (mounted.current) setError(caught instanceof Error ? caught.message : 'This action could not be completed. Refresh the status before retrying.')
    } finally { busyRef.current = false; if (mounted.current) setBusy(false) }
  }

  function portal(intent: 'sso' | 'dsync') {
    if (selectedId === null) return
    const id = selectedId
    void run(async () => {
      const response = await openEnterprisePortal(id, intent, `${window.location.origin}/?enterprise=1`)
      if (!mounted.current) return
      const url = new URL(response.url)
      if (url.protocol !== 'https:' || url.port || url.username || url.password || !['setup.workos.com', import.meta.env.VITE_WORKOS_ADMIN_PORTAL_HOSTNAME].filter(Boolean).includes(url.hostname)) throw new Error('The secure setup link could not be verified. Contact your app administrator.')
      if (!Number.isFinite(Date.parse(response.expires_at)) || Date.parse(response.expires_at) <= Date.now()) throw new Error('The setup link expired. Open a new setup session.')
      window.location.assign(url.href)
    })
  }

  function create(event: FormEvent) {
    event.preventDefault()
    if (!currentUser.is_admin || !name.trim() || !/^org_[a-zA-Z0-9]+$/.test(workosId.trim()) || !Number.isSafeInteger(Number(workspaceId)) || Number(workspaceId) <= 0) return
    const values: EnterpriseInput = { name: name.trim(), workos_organization_id: workosId.trim(), coach_workspace_id: Number(workspaceId), active: true, require_sso: true, directory_provisioning_enabled: false, directory_id: null }
    void run(async () => { const result = await createEnterpriseOrganization(values); if (!mounted.current) return; setNewOrganization(false); setName(''); setWorkosId(''); setWorkspaceId(''); await load(result.enterprise_organization.id) }, 'Organization connected. Add the approved participant groups before onboarding users.')
  }

  const organization = detail?.enterprise_organization
  const selectedOrganization = organizations.find(org => org.id === selectedId)
  return <div className="pilot-dialog-overlay" onClick={event => { if (event.target === event.currentTarget) onClose() }}>
    <section ref={dialog} className="pilot-dialog enterprise-settings" role="dialog" aria-modal="true" aria-labelledby="enterprise-settings-title" tabIndex={-1}>
      <header className="pilot-dialog-header"><div><p className="eyebrow">Organization access</p><h2 id="enterprise-settings-title">Sign-in &amp; provisioning</h2></div><Button variant="secondary" size="compact" onClick={onClose}>Close</Button></header>
      <div className="pilot-dialog-body enterprise-settings-body">
        <p>Connect company sign-in and manage assigned users. Household financial information stays in each person’s private workspace.</p>
        {error && <div className="document-alert" role="alert"><p>{error}</p><Button variant="secondary" size="compact" disabled={busy} onClick={() => void load(selectedId)}>Refresh status</Button>{organizationSignInRequired && selectedOrganization && signIn && <Button disabled={busy} onClick={() => void run(() => signIn({ organizationId: selectedOrganization.workos_organization_id, returnTo: '/organization-access' }))}>Sign in to {selectedOrganization.name}</Button>}</div>}
        {notice && <p role="status" className="document-alert">{notice}</p>}
        {loading && <p role="status">Checking organization access…</p>}
        {!loading && <>
          <div className="enterprise-toolbar">
            {organizations.length > 0 && <label>Organization<select value={selectedId ?? ''} disabled={busy} onChange={event => {setNotice(null); setNewOrganization(false); void load(Number(event.target.value))}}>{organizations.map(org => <option key={org.id} value={org.id}>{org.name}</option>)}</select></label>}
            {currentUser.is_admin && <Button variant="secondary" disabled={busy} onClick={() => setNewOrganization(value => !value)}>{newOrganization ? 'Cancel new organization' : 'Connect an organization'}</Button>}
          </div>
          {!organizations.length && !error && <p>No company connections yet.{currentUser.is_admin ? ' Connect an organization when its WorkOS setup is ready.' : ' Ask your app administrator to assign organization access.'}</p>}
          {newOrganization && currentUser.is_admin && <form className="enterprise-form" onSubmit={create}>
            <h3>Connect an organization</h3>
            <label>Organization name<input required value={name} onChange={event => setName(event.target.value)} disabled={busy} maxLength={120} /></label>
            <label>WorkOS organization ID<input required value={workosId} onChange={event => setWorkosId(event.target.value)} disabled={busy} pattern="org_[a-zA-Z0-9]+" autoCapitalize="none" spellCheck={false} /></label>
            <label>Coaching workspace<select required value={workspaceId} disabled={busy} onChange={event => setWorkspaceId(event.target.value)}><option value="">Choose a workspace</option>{currentUser.coach_workspaces?.map(workspace => <option key={workspace.id} value={workspace.id}>{workspace.name}</option>)}</select></label>
            <p>Company SSO is required. Participants will be admitted only through the approved group mappings below.</p>
            <Button type="submit" disabled={busy}>{busy ? 'Connecting…' : 'Connect organization'}</Button>
          </form>}
          {organization && <>
            <section className="enterprise-section"><h3>{organization.name}</h3><Button variant="ghost" size="compact" disabled={busy} onClick={() => void load(organization.id)}>Refresh status</Button>
              <dl className="enterprise-status-grid"><div><dt>Company sign-in</dt><dd>{organization.connection_state ?? 'Not connected'}</dd></div><div><dt>User provisioning</dt><dd>{organization.directory_state ?? 'Not connected'}</dd></div><div><dt>Access policy</dt><dd>{organization.active ? organization.require_sso ? 'Company SSO required' : 'Organization policy' : 'Organization disabled'}</dd></div><div><dt>Last checked</dt><dd>{organization.last_reconciled_at ? new Date(organization.last_reconciled_at).toLocaleString() : 'Not checked yet'}</dd></div></dl>
              {organization.last_sync_error && <p role="alert">Provisioning needs attention. Refresh the status; if it persists, contact your app administrator.</p>}
              {organization.setup_enabled === false && <p>Company sign-in and user provisioning are not activated. Contact your app administrator.</p>}
              <div className="enterprise-actions"><Button disabled={busy || !organization.active || organization.setup_enabled === false} onClick={() => portal('sso')}>Configure company sign-in</Button><Button variant="secondary" disabled={busy || !organization.active || organization.setup_enabled === false} onClick={() => portal('dsync')}>Configure user provisioning</Button><Button variant="ghost" disabled={busy} onClick={() => void run(() => reconcileEnterpriseOrganization(organization.id), 'Sync requested. Refresh status in a moment to see the result.')}>Refresh from WorkOS</Button></div>
            </section>
            {currentUser.is_admin && <section className="enterprise-section"><h3>Automatic participant accounts</h3><p>{organization.directory_provisioning_enabled ? 'Create accounts for newly assigned users in approved directory groups.' : 'Automatic account creation is paused while the company connection is prepared.'} Existing access continues to follow approved assignments.</p><label><input type="checkbox" checked={admissionReviewed} disabled={busy} onChange={event => setAdmissionReviewed(event.target.checked)} />{organization.directory_provisioning_enabled ? 'I reviewed the impact of pausing automatic account creation.' : 'WorkOS directory provisioning is enabled, and the company sign-in, directory, and participant groups have been tested.'}</label><Button variant="secondary" disabled={busy || !admissionReviewed || !organization.directory_provisioning_enabled && (organization.connection_state !== 'active' || organization.directory_state !== 'active' || !detail.group_mappings.some(mapping => mapping.active))} onClick={() => void run(() => updateEnterpriseOrganization(organization.id, { directory_provisioning_enabled: !organization.directory_provisioning_enabled }), 'Automatic account creation updated. Refresh from WorkOS to synchronize assigned users.')}>{organization.directory_provisioning_enabled ? 'Pause automatic accounts' : 'Enable automatic accounts'}</Button></section>}
            <section className="enterprise-section"><h3>Approved participant groups</h3><p>Only these directory groups enroll participants in the selected programs. Coaching and administrator permissions are assigned separately.</p>
              {detail.group_mappings.length === 0 && <p>No participant groups approved yet.</p>}
              <ul className="enterprise-records">{detail.group_mappings.map(mapping => <li key={mapping.id}><div><strong>{detail.eligible_cohorts.find(cohort => cohort.id === mapping.cohort_id)?.name ?? `Program ${mapping.cohort_id}`}</strong><span>{mapping.workos_group_id}</span><small>{mapping.active ? 'Approved' : 'Disabled'}</small></div>{currentUser.is_admin && <Button variant="secondary" size="compact" disabled={busy} onClick={() => void run(() => updateEnterpriseGroupMapping(organization.id, mapping.id, !mapping.active), 'Group mapping updated. Refresh from WorkOS to reconcile assigned access.')}>{mapping.active ? 'Disable mapping' : 'Enable mapping'}</Button>}</li>)}</ul>
              {currentUser.is_admin && <form className="enterprise-form" onSubmit={event => {event.preventDefault(); if (!groupId.trim() || !detail.eligible_cohorts.some(cohort => cohort.id === Number(cohortId))) return; void run(async () => {await createEnterpriseGroupMapping(organization.id, groupId.trim(), Number(cohortId)); if (mounted.current) {setGroupId('');setCohortId('')}}, 'Participant group approved. Refresh from WorkOS to synchronize assigned users.')}}><label>WorkOS directory group ID<input value={groupId} onChange={event => setGroupId(event.target.value)} disabled={busy} required autoCapitalize="none" spellCheck={false} /></label><label>Program<select value={cohortId} onChange={event => setCohortId(event.target.value)} disabled={busy} required><option value="">Choose a program</option>{detail.eligible_cohorts.map(cohort => <option key={cohort.id} value={cohort.id}>{cohort.name}</option>)}</select></label><Button type="submit" variant="secondary" disabled={busy}>Approve participant group</Button></form>}
            </section>
            <section className="enterprise-section"><h3>Assigned users</h3><p>IT access permits company connection management. It does not grant access to anyone else’s finances.</p>
              {!members.length && <p>No assigned users synchronized yet.</p>}
              <ul className="enterprise-records">{members.map(member => <li key={member.id}><div><strong>{member.full_name || member.email || 'Awaiting participant admission'}</strong><span>{member.email ?? 'Identity sync pending'}</span><small>{member.locally_revoked ? 'App access blocked' : member.status}{member.it_admin ? ' · IT administrator' : ''}</small></div>{currentUser.is_admin && detail.can_manage_memberships && <Button variant="secondary" size="compact" disabled={busy || !member.user_id || member.status !== 'active' || member.locally_revoked} onClick={() => setConfirmation({member, itAdmin: !member.it_admin})}>{member.it_admin ? 'Remove IT access' : 'Review IT access'}</Button>}</li>)}</ul>
              {confirmation && <div className="enterprise-confirmation"><h4>{confirmation.itAdmin ? 'Grant IT configuration access?' : 'Remove IT configuration access?'}</h4><p>{confirmation.member.email} {confirmation.itAdmin ? 'will be able to configure this organization’s company sign-in and provisioning.' : 'will no longer be able to configure this organization’s company sign-in and provisioning.'}</p><div className="enterprise-actions"><Button disabled={busy} onClick={() => void run(async () => {await updateEnterpriseMember(organization.id, confirmation.member.id, {it_admin: confirmation.itAdmin}); if (mounted.current) setConfirmation(null)}, 'IT configuration access updated.')}>Confirm IT access change</Button><Button variant="secondary" disabled={busy} onClick={() => setConfirmation(null)}>Keep current access</Button></div></div>}
            </section>
          </>}
        </>}
      </div>
    </section>
  </div>
}
