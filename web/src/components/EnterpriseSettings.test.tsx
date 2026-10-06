// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as api from '../enterpriseApi'
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
