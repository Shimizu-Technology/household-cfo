// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { useState } from 'react'
import type { CurrentUser } from './api'

const state = vi.hoisted(() => ({ auth: {
  currentUser: null as CurrentUser | null, isAuthEnabled: true, isSignedIn: true, isLoading: false, isVerifyingApi: false,
  authRecoveryRequired: false, authError: null as string | null, authErrorStatus: null as number | null,
  authProvider: 'test', authIdentityId: 'staff', activeCoachWorkspaceId: null, signOut: vi.fn(), signIn: vi.fn(), refreshCurrentUser: vi.fn(),
} }))
vi.mock('./contexts/authContextValue', () => ({ useAuthContext: () => state.auth }))
vi.mock('./components/CoachStudio', () => ({ CoachStudio: ({ onDirtyChange }: { onDirtyChange: (dirty: boolean) => void }) => {
  const [settings, setSettings] = useState(false)
  return <><h2 data-page-heading tabIndex={-1}>Coach Studio</h2><button onClick={() => onDirtyChange(true)}>Edit coaching</button><button onClick={() => setSettings(true)}>Program settings</button><p>{settings ? 'Program identity saved' : 'Daily coaching'}</p></>
} }))
vi.mock('./components/AdminConsole', () => ({ AdminConsole: () => <h2 data-page-heading tabIndex={-1}>Program operations</h2> }))
vi.mock('./components/ParticipantProgramPicker', () => ({ ParticipantProgramPicker: () => null }))
vi.mock('./components/ParticipantProgramSession', () => ({ ParticipantProgramSession: () => <p>Participant session mounted</p> }))
import App from './App'

const user = (admin = false): CurrentUser => ({ id: 20, clerk_id: 'staff', email: 'staff@example.invalid', full_name: 'Coach Test', first_name: 'Coach', last_name: 'Test', role: admin ? 'admin' : 'coach', invitation_status: 'accepted', invited_at: null, accepted_at: null, last_sign_in_at: null, created_at: '', is_admin: admin, is_coach: true, is_staff: true, is_participant: false })
beforeEach(() => {
  window.history.replaceState({}, '', '/')
  Object.assign(state.auth, { currentUser: user(), isAuthEnabled: true, isSignedIn: true, isLoading: false, isVerifyingApi: false, authError: null, authRecoveryRequired: false })
})
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.resetAllMocks() })

it('opens staff in Daily coaching without mounting the participant session or money controls', () => {
  render(<App />)
  expect(screen.getByText('Daily coaching')).toBeTruthy()
  expect(screen.getByRole('navigation', { name: 'Staff sections' })).toBeTruthy()
  expect(window.location.hash).toBe('#Coach%20Studio')
  expect(screen.queryByText('Participant session mounted')).toBeNull()
  expect(screen.queryByRole('link', { name: 'Home' })).toBeNull()
  expect(screen.queryByRole('button', { name: 'Reset my test workspace' })).toBeNull()
})

it('denies household and unauthorized Admin hashes while preserving the staff screen', () => {
  window.history.replaceState({}, '', '/#Budget')
  render(<App />)
  expect(window.location.hash).toBe('#Coach%20Studio')
  expect(screen.getByRole('status').textContent).toContain('Household money is not available')
  act(() => { window.dispatchEvent(new HashChangeEvent('hashchange')) })
  expect(screen.getByRole('status').textContent).toContain('Household money is not available')
  act(() => { window.history.pushState({}, '', '/#Admin'); window.dispatchEvent(new PopStateEvent('popstate')) })
  expect(window.location.hash).toBe('#Coach%20Studio')
  expect(screen.queryByText('Program operations')).toBeNull()
})

it('keeps dirty Studio edits when staff cancels navigation and allows an approved transition', () => {
  state.auth.currentUser = user(true)
  const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false)
  render(<App />)
  fireEvent.click(screen.getByRole('button', { name: 'Edit coaching' }))
  fireEvent.click(screen.getByRole('link', { name: 'Admin' }))
  expect(window.location.hash).toBe('#Coach%20Studio')
  expect(screen.getByText('Daily coaching')).toBeTruthy()
  confirm.mockReturnValue(true)
  fireEvent.click(screen.getByRole('link', { name: 'Admin' }))
  expect(window.location.hash).toBe('#Admin')
  expect(screen.getByRole('heading', { name: 'Program operations' })).toBeTruthy()
})

it('keeps authentication verification closed and preserves participant seats on mixed-role accounts', () => {
  state.auth.isVerifyingApi = true
  state.auth.isAuthEnabled = false
  const view = render(<App />)
  expect(screen.queryByRole('navigation', { name: 'Staff sections' })).toBeNull()
  state.auth.isVerifyingApi = false
  state.auth.currentUser = { ...user(true), is_participant: true }
  view.rerender(<App />)
  expect(screen.getByText('Participant session mounted')).toBeTruthy()
  expect(screen.queryByRole('navigation', { name: 'Staff sections' })).toBeNull()
})

it('preserves Studio position and dirty guards across a same-account refresh while hiding access until it settles', () => {
  state.auth.currentUser = user(true)
  const view = render(<App />)
  fireEvent.click(screen.getByRole('button', { name: 'Program settings' }))
  fireEvent.click(screen.getByRole('button', { name: 'Edit coaching' }))
  state.auth.isVerifyingApi = true
  view.rerender(<App />)
  expect(screen.queryByRole('button', { name: 'Program settings' })).toBeNull()
  state.auth.isVerifyingApi = false
  view.rerender(<App />)
  expect(screen.getByText('Program identity saved')).toBeTruthy()
  const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false)
  fireEvent.click(screen.getByRole('link', { name: 'Admin' }))
  expect(confirm).toHaveBeenCalled()
  expect(window.location.hash).toBe('#Coach%20Studio')
  state.auth.authError = 'Program access ended'
  view.rerender(<App />)
  expect(screen.queryByRole('button', { name: 'Program settings' })).toBeNull()
})
