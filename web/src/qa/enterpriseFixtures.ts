import type { CurrentUser } from '../api'
import type { EnterpriseDetail, EnterpriseMember, EnterpriseOrganization } from '../enterpriseApi'
export function enterpriseUser(admin = false, authorized = true): CurrentUser {
  return { id: 991, clerk_id: 'fictional_enterprise_contact', auth_provider: 'workos', auth_subject: 'fictional_enterprise_contact', email: 'it-contact@company.test', first_name: 'Fictional', last_name: 'IT contact', full_name: 'Fictional IT contact', role: admin ? 'admin' : 'participant', invitation_status: 'accepted', invited_at: null, accepted_at: null, last_sign_in_at: null, created_at: '2026-10-01', is_admin: admin, is_coach: false, is_staff: admin, is_participant: !admin,
    enterprise_access: { can_configure: authorized, organizations: authorized ? [{ id: 1, name: 'Fictional Company', it_admin: true }] : [] },
    coach_workspaces: admin ? [{ id: 71, name: 'Approved coaching workspace', slug: 'fictional', membership_role: 'platform_admin', coach_profile: null }] : [],
  }
}
export function enterpriseOrganization(id = 1): EnterpriseOrganization {
  return { id, name: id === 1 ? 'Fictional Company' : 'Second Company', coach_workspace_id: id === 1 ? 71 : 72, workos_organization_id: `org_FICTIONAL${id}`, active: true, require_sso: true, directory_provisioning_enabled: true, directory_id: `directory_fictional_${id}`, connection_state: 'Company connection ready', directory_state: 'Users synchronized', last_reconciled_at: '2026-10-01T00:00:00Z', last_sync_error: null }
}
export function enterpriseDetail(id = 1, manageMemberships = false): EnterpriseDetail {
  return { enterprise_organization: enterpriseOrganization(id), can_manage_memberships: manageMemberships, eligible_cohorts: [{ id: id === 1 ? 81 : 82, name: id === 1 ? 'Approved savings program' : 'Second approved program' }], group_mappings: [{ id: 1, workos_group_id: `group_fictional_${id}`, cohort_id: id === 1 ? 81 : 82, active: true, role: 'participant' }] }
}
export function enterpriseMember(id = 1): EnterpriseMember {
  return { id, user_id: 991 + id, workos_user_id: `user_fictional_${id}`, full_name: `Assigned fictional contact ${id}`, email: `assigned-contact-${id}@fictional-company.test`, status: 'active', it_admin: false, locally_revoked: false }
}
