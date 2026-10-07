// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as api from '../enterpriseApi'
import { ApiRequestError } from '../api'
import { AuthContext } from '../contexts/authContextValue'
import { EnterpriseSettings } from './EnterpriseSettings'
import { enterpriseDetail, enterpriseMember, enterpriseOrganization, enterpriseUser } from '../qa/enterpriseFixtures'
vi.mock('../enterpriseApi')
beforeEach(() => {
  vi.resetAllMocks()
  vi.mocked(api.fetchEnterpriseOrganizations).mockResolvedValue({ enterprise_organizations: [enterpriseOrganization(1), enterpriseOrganization(2)] })
  vi.mocked(api.fetchEnterpriseOrganization).mockImplementation(async id => enterpriseDetail(id))
  vi.mocked(api.fetchEnterpriseMembers).mockResolvedValue({ memberships: [enterpriseMember()] })
})
afterEach(cleanup)
async function open(admin = false) {
  const view = render(<EnterpriseSettings currentUser={enterpriseUser(admin)} onClose={vi.fn()} />)
  await screen.findByRole('heading', { name: 'Fictional Company' })
  return view
}
describe('enterprise configuration scope', () => {
  it('shows IT connection management without finance or platform administrator controls', async () => {
    await open()
    expect(screen.getByRole('button', { name: 'Configure company sign-in' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Configure user provisioning' })).toBeTruthy()
    expect(screen.queryByRole('button', { name: 'Connect an organization' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Approve participant group' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Review IT access' })).toBeNull()
  })
  it('never exposes IT grants to a non-platform admin even with an inconsistent capability flag', async () => {
    vi.mocked(api.fetchEnterpriseOrganization).mockResolvedValue(enterpriseDetail(1, true))
    await open()
    expect(screen.queryByRole('button', { name: 'Review IT access' })).toBeNull()
  })
  it('requires an explicit review and confirmation before a platform admin grants IT scope', async () => {
    vi.mocked(api.fetchEnterpriseOrganization).mockResolvedValue(enterpriseDetail(1, true))
    vi.mocked(api.updateEnterpriseMember).mockResolvedValue({ membership: { ...enterpriseMember(), it_admin: true } })
    await open(true)
    expect(api.updateEnterpriseMember).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Review IT access' }))
    expect(screen.getByRole('heading', { name: 'Grant IT configuration access?' })).toBeTruthy()
    expect(api.updateEnterpriseMember).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Keep current access' }))
    expect(screen.queryByRole('heading', { name: 'Grant IT configuration access?' })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Review IT access' }))
    fireEvent.click(screen.getByRole('button', { name: 'Confirm IT access change' }))
    await waitFor(() => expect(api.updateEnterpriseMember).toHaveBeenCalledWith(1, 1, { it_admin: true }))
  })
  it('offers only eligible programs when approving a participant directory group', async () => {
    vi.mocked(api.createEnterpriseGroupMapping).mockResolvedValue({ group_mapping: { id: 2, workos_group_id: 'group_APPROVED', cohort_id: 81, active: true, role: 'participant' } })
    await open(true)
    const options = Array.from((screen.getByLabelText('Program') as HTMLSelectElement).options).map(option => option.value)
    expect(options).toEqual(['', '81'])
    fireEvent.change(screen.getByLabelText('WorkOS directory group ID'), { target: { value: 'group_APPROVED' } })
    fireEvent.change(screen.getByLabelText('Program'), { target: { value: '81' } })
    fireEvent.click(screen.getByRole('button', { name: 'Approve participant group' }))
    await waitFor(() => expect(api.createEnterpriseGroupMapping).toHaveBeenCalledWith(1, 'group_APPROVED', 81))
  })
  it('clears one organization’s mapping draft before another organization can use it', async () => {
    await open(true)
    fireEvent.change(screen.getByLabelText('WorkOS directory group ID'), { target: { value: 'group_ONLY_A' } })
    fireEvent.change(screen.getByLabelText('Program'), { target: { value: '81' } })
    fireEvent.change(screen.getByLabelText('Organization'), { target: { value: '2' } })
    await screen.findByRole('heading', { name: 'Second Company' })
    expect(screen.getByLabelText('WorkOS directory group ID')).toHaveProperty('value', '')
    expect(screen.getByLabelText('Program')).toHaveProperty('value', '')
  })
})
describe('enterprise response isolation and recovery', () => {
  it('ignores a late response and late error after a refresh supersedes it', async () => {
    let rejectOld!: (error: Error) => void
    vi.mocked(api.fetchEnterpriseOrganization).mockImplementationOnce(() => new Promise((_resolve, reject) => { rejectOld = reject }))
    vi.mocked(api.fetchEnterpriseMembers).mockRejectedValueOnce(new Error('Roster unavailable'))
    render(<EnterpriseSettings currentUser={enterpriseUser()} onClose={vi.fn()} />)
    await screen.findByText('Roster unavailable')
    fireEvent.click(screen.getByRole('button', { name: 'Refresh status' }))
    await screen.findByRole('heading', { name: 'Fictional Company' })
    await act(async () => rejectOld(new Error('Obsolete organization error')))
    expect(screen.queryByText('Obsolete organization error')).toBeNull()
  })
  it('ignores late successful detail after its roster failure and a newer refresh', async () => {
    let complete!: (detail: api.EnterpriseDetail) => void
    vi.mocked(api.fetchEnterpriseOrganization).mockImplementationOnce(() => new Promise(resolve => { complete = resolve }))
    vi.mocked(api.fetchEnterpriseMembers).mockRejectedValueOnce(new Error('Old roster failed'))
    render(<EnterpriseSettings currentUser={enterpriseUser()} onClose={vi.fn()} />)
    await screen.findByText('Old roster failed')
    const oldSignal = vi.mocked(api.fetchEnterpriseOrganization).mock.calls[0][1]!
    fireEvent.click(screen.getByRole('button', { name: 'Refresh status' }))
    await screen.findByRole('heading', { name: 'Fictional Company' })
    expect(oldSignal.aborted).toBe(true)
    await act(async () => complete(enterpriseDetail(2, true)))
    expect(screen.queryByRole('heading', { name: 'Second Company' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Review IT access' })).toBeNull()
  })
  it('rejects detail for a different organization and recovers with a fresh load', async () => {
    vi.mocked(api.fetchEnterpriseOrganization).mockResolvedValueOnce(enterpriseDetail(2))
    render(<EnterpriseSettings currentUser={enterpriseUser()} onClose={vi.fn()} />)
    await screen.findByText('The organization response could not be verified. Reload this screen.')
    expect(screen.queryByRole('button', { name: 'Configure company sign-in' })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Refresh status' }))
    await screen.findByRole('heading', { name: 'Fictional Company' })
  })
  it('cancels outstanding reads when configuration closes', async () => {
    vi.mocked(api.fetchEnterpriseOrganization).mockImplementation(() => new Promise(() => undefined))
    const view = render(<EnterpriseSettings currentUser={enterpriseUser()} onClose={vi.fn()} />)
    await waitFor(() => expect(api.fetchEnterpriseOrganization).toHaveBeenCalledOnce())
    const signal = vi.mocked(api.fetchEnterpriseOrganization).mock.calls[0][1]!
    view.unmount()
    expect(signal.aborted).toBe(true)
    expect(document.body.style.overflow).not.toBe('hidden')
  })
  it.each(['https://setup.workos.com.evil.test/setup', 'http://setup.workos.com/setup', 'https://user:secret@setup.workos.com/setup', 'https://setup.workos.com:8443/setup'])('rejects an unverified portal destination %s', async url => {
    vi.mocked(api.openEnterprisePortal).mockResolvedValue({ url, expires_at: new Date(Date.now() + 60_000).toISOString() })
    await open()
    fireEvent.click(screen.getByRole('button', { name: 'Configure company sign-in' }))
    await screen.findByText('The secure setup link could not be verified. Contact your app administrator.')
  })
  it('rejects an expired portal link and preserves retry controls', async () => {
    vi.mocked(api.openEnterprisePortal).mockResolvedValue({ url: 'https://setup.workos.com/setup', expires_at: '2020-01-01T00:00:00Z' })
    await open()
    fireEvent.click(screen.getByRole('button', { name: 'Configure user provisioning' }))
    await screen.findByText('The setup link expired. Open a new setup session.')
    expect(screen.getByRole('button', { name: 'Configure user provisioning' })).toHaveProperty('disabled', false)
    expect(api.openEnterprisePortal).toHaveBeenCalledWith(1, 'dsync', `${window.location.origin}/?enterprise=1`)
  })
})

describe('organization-specific admission controls', () => {
  it('uses the selected organization’s opaque ID for SSO recovery after minimal list metadata', async () => {
    const signIn = vi.fn().mockResolvedValue(undefined)
    vi.mocked(api.fetchEnterpriseOrganizations).mockResolvedValue({ enterprise_organizations: [{ id: 1, name: 'Fictional Company', workos_organization_id: 'org_FICTIONAL1' }] })
    vi.mocked(api.fetchEnterpriseOrganization).mockRejectedValue(new ApiRequestError('Sign in to this organization first.', { status: 403, code: 'enterprise_organization_signin_required' }))
    render(<AuthContext.Provider value={{ isClerkEnabled: false, authProvider: 'workos', authIdentityId: 'fictional', isSignedIn: true, isLoading: false, isVerifyingApi: false, currentUser: enterpriseUser(), activeCoachWorkspaceId: null, authError: null, refreshCurrentUser: async () => undefined, selectCoachWorkspace: () => undefined, signIn }}><EnterpriseSettings currentUser={enterpriseUser()} onClose={vi.fn()} /></AuthContext.Provider>)
    fireEvent.click(await screen.findByRole('button', { name: 'Sign in to Fictional Company' }))
    await waitFor(() => expect(signIn).toHaveBeenCalledWith({ organizationId: 'org_FICTIONAL1', returnTo: '/organization-access' }))
    expect(screen.queryByRole('button', { name: 'Configure company sign-in' })).toBeNull()
  })
  it('requires platform admin review before pausing automatic account creation', async () => {
    vi.mocked(api.updateEnterpriseOrganization).mockResolvedValue({ enterprise_organization: { ...enterpriseOrganization(), directory_provisioning_enabled: false } })
    await open(true)
    const pause = screen.getByRole('button', { name: 'Pause automatic accounts' })
    expect(pause).toHaveProperty('disabled', true)
    fireEvent.click(screen.getByLabelText('I reviewed the impact of pausing automatic account creation.'))
    fireEvent.click(pause)
    await waitFor(() => expect(api.updateEnterpriseOrganization).toHaveBeenCalledWith(1, { directory_provisioning_enabled: false }))
  })
  it('keeps automatic account creation controls hidden from IT contacts', async () => {
    await open()
    expect(screen.queryByRole('heading', { name: 'Automatic participant accounts' })).toBeNull()
    expect(api.updateEnterpriseOrganization).not.toHaveBeenCalled()
  })
  it.each(['connection', 'directory', 'groups'])('blocks enablement despite review when %s setup is not active', async missing => {
    const detail = enterpriseDetail()
    detail.enterprise_organization = { ...detail.enterprise_organization, directory_provisioning_enabled: false, connection_state: missing === 'connection' ? 'inactive' : 'active', directory_state: missing === 'directory' ? 'inactive' : 'active' }
    if (missing === 'groups') detail.group_mappings = []
    vi.mocked(api.fetchEnterpriseOrganization).mockResolvedValue(detail)
    await open(true)
    fireEvent.click(screen.getByRole('checkbox'))
    const enable = screen.getByRole('button', { name: 'Enable automatic accounts' })
    expect(enable).toHaveProperty('disabled', true)
    fireEvent.click(enable)
    expect(api.updateEnterpriseOrganization).not.toHaveBeenCalled()
  })
  it('enables reviewed admission only after active company sign-in, directory, and approved groups', async () => {
    const detail = enterpriseDetail()
    detail.enterprise_organization = { ...detail.enterprise_organization, directory_provisioning_enabled: false, connection_state: 'active', directory_state: 'active' }
    vi.mocked(api.fetchEnterpriseOrganization).mockResolvedValue(detail)
    vi.mocked(api.updateEnterpriseOrganization).mockResolvedValue({ enterprise_organization: { ...detail.enterprise_organization, directory_provisioning_enabled: true } })
    await open(true)
    const enable = screen.getByRole('button', { name: 'Enable automatic accounts' })
    expect(enable).toHaveProperty('disabled', true)
    fireEvent.click(screen.getByRole('checkbox'))
    fireEvent.click(enable)
    await waitFor(() => expect(api.updateEnterpriseOrganization).toHaveBeenCalledWith(1, { directory_provisioning_enabled: true }))
  })
  it('never grants IT access to an unbound pre-provisioned directory member', async () => {
    vi.mocked(api.fetchEnterpriseOrganization).mockResolvedValue(enterpriseDetail(1, true))
    vi.mocked(api.fetchEnterpriseMembers).mockResolvedValue({ memberships: [{ ...enterpriseMember(), user_id: null, email: null, full_name: null }] })
    await open(true)
    expect(screen.getByText('Awaiting participant admission')).toBeTruthy()
    const grant = screen.getByRole('button', { name: 'Review IT access' })
    expect(grant).toHaveProperty('disabled', true)
    fireEvent.click(grant)
    expect(screen.queryByRole('heading', { name: 'Grant IT configuration access?' })).toBeNull()
    expect(api.updateEnterpriseMember).not.toHaveBeenCalled()
  })
})

it('blocks unactivated company setup without calling the vendor portal while status refresh remains available', async () => {
  const detail = enterpriseDetail(); detail.enterprise_organization.setup_enabled = false
  vi.mocked(api.fetchEnterpriseOrganization).mockResolvedValue(detail)
  await open()
  expect(screen.getByText('Company sign-in and user provisioning are not activated. Contact your app administrator.')).toBeTruthy()
  for (const name of ['Configure company sign-in', 'Configure user provisioning']) {
    const button = screen.getByRole('button', { name }); expect(button).toHaveProperty('disabled', true); fireEvent.click(button)
  }
  expect(api.openEnterprisePortal).not.toHaveBeenCalled()
  expect(screen.getByRole('button', { name: 'Refresh status' })).toHaveProperty('disabled', false)
})
