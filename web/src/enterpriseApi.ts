import { fetchPrivateJson } from './api'

export type EnterpriseOrganization = {
  id: number; name: string; coach_workspace_id: number; workos_organization_id: string
  setup_enabled?: boolean; active: boolean; require_sso: boolean; directory_provisioning_enabled: boolean
  directory_id: string | null; connection_state: string | null; directory_state: string | null
  last_reconciled_at: string | null; last_sync_error: string | null
}
export type EnterpriseOrganizationOption = Pick<EnterpriseOrganization, 'id' | 'name' | 'workos_organization_id'>
export type EnterpriseGroupMapping = { id: number; workos_group_id: string; cohort_id: number; active: boolean; role: 'participant' }
export type EnterpriseMember = { id: number; user_id: number | null; workos_user_id: string; status: string; it_admin: boolean; locally_revoked: boolean; email: string | null; full_name: string | null }
export type EnterpriseDetail = { enterprise_organization: EnterpriseOrganization; group_mappings: EnterpriseGroupMapping[]; can_manage_memberships: boolean; eligible_cohorts: Array<{ id: number; name: string }> }
export type EnterpriseCreateInput = Pick<EnterpriseOrganization, 'name' | 'coach_workspace_id' | 'workos_organization_id' | 'require_sso'>
export type EnterpriseUpdateInput = Partial<Pick<EnterpriseOrganization, 'name' | 'active' | 'require_sso' | 'directory_provisioning_enabled'>>

const path = '/api/v1/enterprise_organizations'
function json(method: string, body: unknown): RequestInit {
  return { method, cache: 'no-store', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }
}
export function fetchEnterpriseOrganizations(signal?: AbortSignal) {
  return fetchPrivateJson<{ enterprise_organizations: EnterpriseOrganizationOption[] }>(path, { signal, cache: 'no-store' })
}
export function fetchEnterpriseOrganization(id: number, signal?: AbortSignal) {
  return fetchPrivateJson<EnterpriseDetail>(`${path}/${id}`, { signal, cache: 'no-store' })
}
export function createEnterpriseOrganization(values: EnterpriseCreateInput) {
  return fetchPrivateJson<{ enterprise_organization: EnterpriseOrganization }>(path, json('POST', { enterprise_organization: values }))
}
export function updateEnterpriseOrganization(id: number, values: EnterpriseUpdateInput) {
  return fetchPrivateJson<{ enterprise_organization: EnterpriseOrganization }>(`${path}/${id}`, json('PATCH', { enterprise_organization: values }))
}
export function openEnterprisePortal(id: number, intent: 'sso' | 'dsync', returnUrl: string) {
  return fetchPrivateJson<{ url: string; expires_at: string }>(`${path}/${id}/portal`, json('POST', { intent, return_url: returnUrl }))
}
export function reconcileEnterpriseOrganization(id: number) {
  return fetchPrivateJson<{ queued: boolean }>(`${path}/${id}/reconcile`, json('POST', {}))
}
export function fetchEnterpriseMembers(id: number, signal?: AbortSignal) {
  return fetchPrivateJson<{ memberships: EnterpriseMember[] }>(`${path}/${id}/memberships`, { signal, cache: 'no-store' })
}
export function updateEnterpriseMember(id: number, memberId: number, values: { it_admin?: boolean; locally_revoked?: boolean }) {
  return fetchPrivateJson<{ membership: EnterpriseMember }>(`${path}/${id}/memberships/${memberId}`, json('PATCH', { membership: values }))
}
export function createEnterpriseGroupMapping(id: number, workosGroupId: string, cohortId: number) {
  return fetchPrivateJson<{ group_mapping: EnterpriseGroupMapping }>(`${path}/${id}/group_mappings`, json('POST', { group_mapping: { workos_group_id: workosGroupId, cohort_id: cohortId, active: true } }))
}
export function updateEnterpriseGroupMapping(id: number, mappingId: number, active: boolean) {
  return fetchPrivateJson<{ group_mapping: EnterpriseGroupMapping }>(`${path}/${id}/group_mappings/${mappingId}`, json('PATCH', { group_mapping: { active } }))
}
