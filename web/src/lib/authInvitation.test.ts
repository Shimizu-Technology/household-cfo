// @vitest-environment jsdom
import { afterEach, expect, it } from 'vitest'
import { captureAuthInvitation } from './authInvitation'
import { authReturnState } from './authNavigation'

afterEach(() => { window.history.replaceState(null, '', '/') })
it('captures an opaque invitation for PKCE while removing it from the URL and navigation state', () => {
  window.history.replaceState(null, '', '/login?invitation_token=fictional%2Bopaque%2Ftoken%3D&returnTo=%2Forganization-access')
  expect(captureAuthInvitation()).toEqual({ token: 'fictional+opaque/token=', error: null })
  expect(window.location.href).not.toContain('invitation_token')
  expect(authReturnState().returnTo).toBe(`${window.location.origin}/organization-access`)
  expect(JSON.stringify(authReturnState())).not.toContain('opaque')
})
it.each(['', 'one&invitation_token=two', '%00hidden', 'spaces%20inside', 'a'.repeat(4097)])('rejects malformed invitation links and strips the credential: %s', value => {
  window.history.replaceState(null, '', `/login?invitation_token=${value}`)
  expect(captureAuthInvitation()).toEqual({ token: null, error: expect.stringContaining('resend') })
  expect(window.location.search).not.toContain('invitation_token')
})
it('does not consume an invitation on an unrelated path', () => {
  window.history.replaceState(null, '', '/organization-access?invitation_token=fictional')
  expect(captureAuthInvitation().token).toBeNull()
  expect(window.location.search).toBe('')
})
