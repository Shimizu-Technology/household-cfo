// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { useState } from 'react'
import type { CurrentUser } from './api'

const state = vi.hoisted(() => ({ auth: {
  currentUser: null as CurrentUser | null, isAuthEnabled: true, isSignedIn: true, isLoading: false, isVerifyingApi: false,
  authRecoveryRequired: false, authError: null as string | null, authErrorStatus: null as number | null,
  authProvider: 'test', authIdentityId: 'staff', activeCoachWorkspaceId: null as number | null, signOut: vi.fn(), signIn: vi.fn(), refreshCurrentUser: vi.fn(), selectCoachWorkspace: vi.fn(),
} }))
vi.mock('./contexts/authContextValue', () => ({ useAuthContext: () => state.auth }))
vi.mock('./components/CoachStudio', () => ({ CoachStudio: ({ onDirtyChange }: { onDirtyChange: (dirty: boolean) => void }) => {
  const [settings, setSettings] = useState(false)
  return <><h2 data-page-heading tabIndex={-1}>Coaching</h2><button onClick={() => onDirtyChange(true)}>Edit coaching</button><button onClick={() => onDirtyChange(false)}>Save coaching</button><button onClick={() => setSettings(true)}>Program settings</button><p>{settings ? 'Program identity saved' : 'Daily coaching'}</p></>
} }))
const sectionStub = (name: string) => () => <h2 data-page-heading tabIndex={-1}>{name}</h2>
vi.mock('./admin/sections/TodaySection', () => ({ TodaySection: sectionStub('Today') }))
vi.mock('./admin/sections/PeopleSection', () => ({ PeopleSection: sectionStub('People') }))
vi.mock('./admin/sections/GroupsSection', () => ({ GroupsSection: sectionStub('Groups') }))
vi.mock('./admin/sections/ReportsSection', () => ({ ReportsSection: () => <><h2 data-page-heading tabIndex={-1}>Reports</h2><p>Day 30 report</p></> }))
vi.mock('./admin/sections/SupportSection', () => ({ SupportSection: sectionStub('Support') }))
vi.mock('./admin/sections/SettingsSection', () => ({ SettingsSection: sectionStub('Settings') }))
vi.mock('./components/ParticipantProgramPicker', () => ({ ParticipantProgramPicker: () => null }))
vi.mock('./components/ParticipantProgramSession', () => ({ ParticipantProgramSession: () => <p>Participant session mounted</p> }))
vi.mock('./api', async importOriginal => ({ ...(await importOriginal<typeof import('./api')>()), fetchAdminPersonaAssignableCohorts: vi.fn().mockResolvedValue([{ id: 1, name: 'Group' }]) }))

type Sections = NonNullable<CurrentUser['admin_sections']>
const section = (key: Sections[number]['key'], label: string, access: 'full' | 'read_only' = 'full') => ({ key, label, access })
const ALL: Sections = [section('today', 'Today'), section('people', 'People'), section('groups', 'Groups'), section('coaching', 'Coaching'), section('reports', 'Reports'), section('support', 'Support'), section('settings', 'Settings')]
const EDITOR: Sections = [section('coaching', 'Coaching')]
const user = (role: 'admin' | 'coach' | 'participant' = 'coach', sections: Sections = role === 'participant' ? [] : ALL): CurrentUser => ({
  id: 20, clerk_id: 'staff', email: 'staff@example.invalid', full_name: 'Coach Test', first_name: 'Coach', last_name: 'Test', role,
  invitation_status: 'accepted', invited_at: null, accepted_at: null, last_sign_in_at: null, created_at: '',
  is_admin: role === 'admin', is_coach: role === 'coach', is_staff: role !== 'participant', is_participant: role === 'participant',
  admin_sections: sections, preview_groups: [], coach_workspaces: [{ id: 5, name: 'Mel program', slug: 'mel', membership_role: 'owner', coach_profile: null }],
})

async function app() { const { default: App } = await import('./App'); return App }
beforeEach(() => {
  vi.resetModules()
  window.localStorage.clear()
  window.history.replaceState({}, '', '/')
  Object.assign(state.auth, { currentUser: user(), isAuthEnabled: true, isSignedIn: true, isLoading: false, isVerifyingApi: false, authError: null, authRecoveryRequired: false, activeCoachWorkspaceId: 5 })
})
afterEach(() => { cleanup(); vi.restoreAllMocks() })

it('lands every signed-in person in the app at /, staff included, with no staff-only shell', async () => {
  const App = await app()
  for (const person of [user('participant'), user('coach'), user('admin')]) {
    state.auth.currentUser = person
    const view = render(<App />)
    expect(screen.getByText('Participant session mounted')).toBeTruthy()
    expect(screen.queryByRole('navigation', { name: 'Staff sections' })).toBeNull()
    expect(window.location.pathname).toBe('/')
    view.unmount()
  }
})

it('opens /admin/<section> with the sections the server gave this person, in a sidebar and a phone menu', async () => {
  const App = await app()
  window.history.replaceState({}, '', '/admin/people')
  render(<App />)
  expect(await screen.findByRole('heading', { name: 'People' })).toBeTruthy()
  const sidebar = within(screen.getByRole('navigation', { name: 'Admin' }))
  expect(sidebar.getAllByRole('link').map(link => link.getAttribute('href'))).toEqual(['/admin/today', '/admin/people', '/admin/groups', '/admin/coaching', '/admin/reports', '/admin/support', '/admin/settings', '/'])
  expect(sidebar.getByRole('link', { name: /^People/ }).getAttribute('aria-current')).toBe('page')
  expect(screen.queryByText('Participant session mounted')).toBeNull()
  expect(JSON.parse(window.localStorage.getItem('household-cfo:mode:v1:20')!)).toEqual({ mode: 'admin', section: 'people' })
})

it('shows an editor coach a smaller list and a plain page for a section they do not have', async () => {
  const App = await app()
  state.auth.currentUser = user('coach', EDITOR)
  window.history.replaceState({}, '', '/admin/reports')
  render(<App />)
  expect((await screen.findByRole('alert')).textContent).toContain('That section isn’t part of your role')
  expect(screen.queryByText('Day 30 report')).toBeNull()
  const sidebar = within(screen.getByRole('navigation', { name: 'Admin' }))
  expect(sidebar.queryByRole('link', { name: /^Reports/ })).toBeNull()
  expect(sidebar.queryByRole('link', { name: /^Settings/ })).toBeNull()
  expect(sidebar.getByRole('link', { name: /^Coaching/ })).toBeTruthy()
  expect(sidebar.queryByRole('link', { name: /^People/ })).toBeNull()
})

it('shows participants one plain page with a way home, and never the Admin switch', async () => {
  const App = await app()
  state.auth.currentUser = user('participant')
  window.history.replaceState({}, '', '/admin/people')
  render(<App />)
  expect(await screen.findByRole('heading', { name: 'This page is for coaches and program staff' })).toBeTruthy()
  expect(screen.queryByRole('navigation', { name: 'Admin' })).toBeNull()
  const home = screen.getByRole('link', { name: /^Go to/ })
  expect(home.getAttribute('href')).toBe('/')
  fireEvent.click(home)
  await waitFor(() => expect(window.location.pathname).toBe('/'))
  expect(screen.getByText('Participant session mounted')).toBeTruthy()
})

it('sends /admin to the section the person last used, or their first', async () => {
  const App = await app()
  window.history.replaceState({}, '', '/admin')
  const first = render(<App />)
  await waitFor(() => expect(window.location.pathname).toBe('/admin/today'))
  first.unmount()
  window.localStorage.setItem('household-cfo:mode:v1:20', JSON.stringify({ mode: 'admin', section: 'groups' }))
  window.history.replaceState({}, '', '/admin')
  render(<App />)
  await waitFor(() => expect(window.location.pathname).toBe('/admin/groups'))
})

it('keeps old #Coach Studio and #Admin links working by moving them to their sections', async () => {
  const App = await app()
  window.history.replaceState({}, '', '/?pilot=1#Coach%20Studio')
  const view = render(<App />)
  await waitFor(() => expect(window.location.pathname).toBe('/admin/coaching'))
  expect(window.location.search).toBe('?pilot=1')
  view.unmount()
  window.history.replaceState({}, '', '/?coach_area=assistant#Coach%20Studio')
  const second = render(<App />)
  await waitFor(() => expect(window.location.pathname).toBe('/admin/coaching'))
  expect(window.location.search).toBe('?coach_area=assistant')
  second.unmount()
  window.history.replaceState({}, '', '/#Admin')
  render(<App />)
  await waitFor(() => expect(window.location.pathname).toBe('/admin/people'))
})

it('opens the site again on the side staff last used, but only on a fresh load and never trapping Back', async () => {
  window.localStorage.setItem('household-cfo:mode:v1:20', JSON.stringify({ mode: 'admin', section: 'support' }))
  const App = await app()
  const view = render(<App />)
  await waitFor(() => expect(window.location.pathname).toBe('/admin/support'))
  // Going to the app and then re-rendering must stay on the app.
  fireEvent.click(within(await screen.findByRole('navigation', { name: 'Admin' })).getByRole('link', { name: 'My household' }))
  await waitFor(() => expect(window.location.pathname).toBe('/'))
  view.rerender(<App />)
  expect(window.location.pathname).toBe('/')
  expect(JSON.parse(window.localStorage.getItem('household-cfo:mode:v1:20')!)).toEqual({ mode: 'app' })
})

it('asks before leaving unsaved coaching changes and keeps them when the answer is no', async () => {
  const App = await app()
  window.history.replaceState({}, '', '/admin/coaching')
  render(<App />)
  fireEvent.click(await screen.findByRole('button', { name: 'Edit coaching' }))
  const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false)
  fireEvent.click(within(screen.getByRole('navigation', { name: 'Admin' })).getByRole('link', { name: 'My household' }))
  await waitFor(() => expect(confirm).toHaveBeenCalled())
  expect(window.location.pathname).toBe('/admin/coaching')
  confirm.mockReturnValue(true)
  fireEvent.click(within(screen.getByRole('navigation', { name: 'Admin' })).getByRole('link', { name: 'My household' }))
  await waitFor(() => expect(window.location.pathname).toBe('/'))
})

it('keeps the verified Admin side mounted but hidden while access is rechecked, and closes it on an access error', async () => {
  const App = await app()
  window.history.replaceState({}, '', '/admin/coaching')
  const view = render(<App />)
  fireEvent.click(await screen.findByRole('button', { name: 'Program settings' }))
  state.auth.isVerifyingApi = true
  view.rerender(<App />)
  expect(screen.queryByRole('button', { name: 'Program settings' })).toBeNull()
  state.auth.isVerifyingApi = false
  view.rerender(<App />)
  expect(screen.getByText('Program identity saved')).toBeTruthy()
  state.auth.authError = 'Program access ended'
  state.auth.authRecoveryRequired = false
  view.rerender(<App />)
  expect(screen.queryByRole('button', { name: 'Program settings' })).toBeNull()
})

it('asks an administrator who works across programs which program they are in, and keeps one picker', async () => {
  const App = await app()
  state.auth.currentUser = { ...user('admin'), coach_workspaces: [
    { id: 5, name: 'Mel program', slug: 'mel', membership_role: 'platform_admin', coach_profile: null },
    { id: 6, name: 'Other program', slug: 'other', membership_role: 'platform_admin', coach_profile: null },
  ] }
  state.auth.activeCoachWorkspaceId = null
  window.history.replaceState({}, '', '/admin/today')
  render(<App />)
  fireEvent.click(await screen.findByRole('button', { name: 'More' }))
  const pickers = await screen.findAllByLabelText('Program')
  expect(pickers.length).toBeGreaterThan(0)
  fireEvent.change(pickers[0], { target: { value: '6' } })
  await waitFor(() => expect(state.auth.selectCoachWorkspace).toHaveBeenCalledWith(6))
  await act(async () => undefined)
})

it('puts the sidebar and the page in separate landmarks, with the sidebar outside <main>', async () => {
  const App = await app()
  window.history.replaceState({}, '', '/admin/people')
  render(<App />)
  const nav = await screen.findByRole('navigation', { name: 'Admin' })
  const mains = screen.getAllByRole('main')
  expect(mains).toHaveLength(1)
  expect(mains[0].contains(nav)).toBe(false)
  expect(nav.closest('main')).toBeNull()
  expect(nav.querySelector('nav')).toBeNull()
  expect(within(mains[0]).getByRole('heading', { name: 'People' })).toBeTruthy()
})

it('moves focus to the new section heading when the section changes, not on first load', async () => {
  const App = await app()
  window.history.replaceState({}, '', '/admin/today')
  render(<App />)
  await screen.findByRole('heading', { name: 'Today' })
  expect(document.activeElement).toBe(document.body)
  fireEvent.click(within(screen.getByRole('navigation', { name: 'Admin' })).getByRole('link', { name: /^People/ }))
  const heading = await screen.findByRole('heading', { name: 'People' })
  await waitFor(() => expect(document.activeElement).toBe(heading))
  fireEvent.click(within(screen.getByRole('navigation', { name: 'Admin' })).getByRole('link', { name: /^Coaching/ }))
  const next = await screen.findByRole('heading', { name: 'Coaching' })
  await waitFor(() => expect(document.activeElement).toBe(next))
})

it('leaves no extra history entry behind once unsaved changes are saved, so the next Back works', async () => {
  const App = await app()
  window.history.replaceState({}, '', '/admin/coaching')
  const back = vi.spyOn(window.history, 'back')
  const view = render(<App />)
  const before = window.history.length
  fireEvent.click(await screen.findByRole('button', { name: 'Edit coaching' }))
  expect(window.history.length).toBe(before + 1)
  expect(window.history.state?.adminLeaveGuard).toBe(true)
  // Saved: the screen reports no unsaved changes again.
  fireEvent.click(screen.getByRole('button', { name: 'Save coaching' }))
  await waitFor(() => expect(back).toHaveBeenCalledTimes(1))
  view.unmount()
})

it('replaces the guard entry when the person leaves, instead of stacking another step', async () => {
  const App = await app()
  window.history.replaceState({}, '', '/admin/coaching')
  render(<App />)
  fireEvent.click(await screen.findByRole('button', { name: 'Edit coaching' }))
  const length = window.history.length
  vi.spyOn(window, 'confirm').mockReturnValue(true)
  fireEvent.click(within(screen.getByRole('navigation', { name: 'Admin' })).getByRole('link', { name: /^People/ }))
  await waitFor(() => expect(window.location.pathname).toBe('/admin/people'))
  expect(window.history.length).toBe(length)
  expect(window.history.state?.adminLeaveGuard).toBeUndefined()
})

it('selects the sole server-provided program without presenting a redundant Program picker', async () => {
  const App = await app()
  state.auth.currentUser = user('admin')
  state.auth.activeCoachWorkspaceId = null
  window.history.replaceState({}, '', '/admin/today')
  render(<App />)
  await waitFor(() => expect(state.auth.selectCoachWorkspace).toHaveBeenCalledWith(5))
  fireEvent.click(screen.getByRole('button', { name: 'More' }))
  expect(screen.queryByLabelText('Program')).toBeNull()
})

it('unmounts the portal sheet and releases its scroll lock while program access is rechecked', async () => {
  const App = await app()
  window.history.replaceState({}, '', '/admin/people')
  const view = render(<App />)
  fireEvent.click(await screen.findByRole('button', { name: 'More' }))
  expect(screen.getByRole('dialog', { name: 'More' })).toBeTruthy()
  expect(document.body.style.overflow).toBe('hidden')
  state.auth.isVerifyingApi = true
  view.rerender(<App />)
  expect(screen.queryByRole('dialog', { name: 'More' })).toBeNull()
  expect(document.body.style.overflow).toBe('')
})
