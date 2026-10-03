// @vitest-environment jsdom

import { useState } from 'react'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import type { CurrentUser } from '../api'
import { AuthContext, type AuthContextValue, useAuthContext } from '../contexts/authContextValue'
import { IdentityBoundary } from './IdentityBoundary'

function authValue(userId: number, overrides: Partial<AuthContextValue> = {}): AuthContextValue {
  return {
    isClerkEnabled: true,
    authIdentityId: `clerk-${userId}`,
    isSignedIn: true,
    isLoading: false,
    isVerifyingApi: false,
    currentUser: { id: userId, clerk_id: `clerk-${userId}` } as CurrentUser,
    activeCoachWorkspaceId: null,
    authError: null,
    refreshCurrentUser: async () => undefined,
    selectCoachWorkspace: () => undefined,
    ...overrides,
  }
}

function PrivateWorkspaceState() {
  const auth = useAuthContext()
  const [value, setValue] = useState(`User ${auth.currentUser?.id ?? 'unknown'} private workspace`)
  if (!auth.currentUser || auth.currentUser.clerk_id !== auth.authIdentityId) {
    return <p>Private workspace pending</p>
  }
  return <button type="button" onClick={() => setValue('Unsaved private state')}>{value}</button>
}

afterEach(() => cleanup())

describe('IdentityBoundary', () => {
  it('remounts private workspace state before a different account can render', () => {
    const view = render(
      <AuthContext.Provider value={authValue(1)}>
        <IdentityBoundary><PrivateWorkspaceState /></IdentityBoundary>
      </AuthContext.Provider>,
    )
    fireEvent.click(screen.getByRole('button', { name: 'User 1 private workspace' }))
    expect(screen.getByRole('button', { name: 'Unsaved private state' })).toBeTruthy()

    view.rerender(
      <AuthContext.Provider value={authValue(2)}>
        <IdentityBoundary><PrivateWorkspaceState /></IdentityBoundary>
      </AuthContext.Provider>,
    )

    expect(screen.queryByRole('button', { name: 'Unsaved private state' })).toBeNull()
    expect(screen.getByRole('button', { name: 'User 2 private workspace' })).toBeTruthy()
  })

  it('remounts before stale API identity can cross a real sign-out and account switch', () => {
    const userA = authValue(1)
    const view = render(
      <AuthContext.Provider value={userA}>
        <IdentityBoundary><PrivateWorkspaceState /></IdentityBoundary>
      </AuthContext.Provider>,
    )
    fireEvent.click(screen.getByRole('button', { name: 'User 1 private workspace' }))

    view.rerender(
      <AuthContext.Provider value={authValue(1, { isSignedIn: false, currentUser: null })}>
        <IdentityBoundary><PrivateWorkspaceState /></IdentityBoundary>
      </AuthContext.Provider>,
    )
    expect(screen.queryByRole('button', { name: 'Unsaved private state' })).toBeNull()
    expect(screen.queryByText('User 1 private workspace')).toBeNull()
    expect(screen.getByText('Private workspace pending')).toBeTruthy()

    view.rerender(
      <AuthContext.Provider value={authValue(1, {
        authIdentityId: 'clerk-2',
        isSignedIn: true,
        isVerifyingApi: true,
      })}>
        <IdentityBoundary><PrivateWorkspaceState /></IdentityBoundary>
      </AuthContext.Provider>,
    )
    expect(screen.queryByRole('button', { name: 'Unsaved private state' })).toBeNull()
    expect(screen.queryByText('User 1 private workspace')).toBeNull()
    expect(screen.getByText('Private workspace pending')).toBeTruthy()

    view.rerender(
      <AuthContext.Provider value={authValue(2)}>
        <IdentityBoundary><PrivateWorkspaceState /></IdentityBoundary>
      </AuthContext.Provider>,
    )
    expect(screen.queryByText('User 1 private workspace')).toBeNull()
    expect(screen.getByRole('button', { name: 'User 2 private workspace' })).toBeTruthy()
  })
})
