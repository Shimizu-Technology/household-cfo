// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { AccountMenu } from './AccountMenu'
const auth = vi.hoisted(() => ({ currentUser: { full_name: 'Ana Santos', email: 'ana@example.invalid', role: 'participant', is_admin: false, is_coach: false }, isAuthEnabled: false }))
vi.mock('../contexts/authContextValue', () => ({ useAuthContext: () => auth }))
vi.mock('./AuthControls', () => ({ SignOutButton: () => null }))
afterEach(() => { cleanup(); auth.currentUser.is_admin = false; auth.currentUser.is_coach = false })
it('uses plain account roles and returns focus on Escape', () => {
  render(<AccountMenu><button>Help</button></AccountMenu>)
  expect(screen.getByText('Household member')).toBeTruthy()
  const summary = screen.getByLabelText('Account and help')
  const menu = summary.closest('details')!
  menu.open = true
  fireEvent.keyDown(screen.getByRole('button', { name: 'Help' }), { key: 'Escape' })
  expect(menu.open).toBe(false)
  expect(document.activeElement).toBe(summary)
})
it('identifies an administrator in plain language', () => {
  auth.currentUser.is_admin = true
  render(<AccountMenu />)
  expect(screen.getByText('Administrator')).toBeTruthy()
})
it('identifies a coach in plain language', () => {
  auth.currentUser.is_coach = true
  render(<AccountMenu />)
  expect(screen.getByText('Coach')).toBeTruthy()
})
