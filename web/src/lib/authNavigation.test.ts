// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest'
import { authReturnState, restoreAuthReturn, safeAuthReturnTo } from './authNavigation'
const origin = 'https://cfo.example.com'
describe('hosted auth navigation', () => {
  it('preserves known deep links but excludes query details from OAuth state', () => {
    expect(safeAuthReturnTo('/?income=4000&token=secret#Ask%20Mia', origin)).toBe(`${origin}/#Ask%20Mia`)
    expect(safeAuthReturnTo('/login#My%20Profile', origin)).toBe(`${origin}/#My%20Profile`)
  })
  it.each(['//evil.example', 'https://evil.example/#Home', 'javascript:alert(1)', '/private-record/7', '/#income=4000', '/#%E0%A4%A', 'https://user:password@cfo.example.com/'])('rejects unsafe or private return destinations %s', value => {
    expect(safeAuthReturnTo(value, origin)).toBe(`${origin}/`)
  })
})

afterEach(() => { window.history.replaceState(null, '', '/'); sessionStorage.clear() })
it('preserves a bank OAuth callback only in the originating tab and excludes it from hosted URL state', () => {
  window.history.replaceState(null, '', '/?oauth_state_id=bank-callback-123&income=4000#My%20Profile')
  const state = authReturnState()
  expect(JSON.stringify(state)).not.toContain('bank-callback-123')
  expect(JSON.stringify(state)).not.toContain('4000')
  expect(state.navigationKey).toBeTruthy()
  window.history.replaceState(null, '', '/auth/callback')
  restoreAuthReturn({ state })
  expect(window.location.search).toBe('?oauth_state_id=bank-callback-123')
  expect(window.location.hash).toBe('#My%20Profile')
  restoreAuthReturn({ state })
  expect(window.location.search).toBe('')
})
it('preserves organization access across hosted sign-in without carrying unrelated query details', () => {
  expect(safeAuthReturnTo('/organization-access?income=4000#Budget', origin)).toBe(`${origin}/organization-access`)
  expect(safeAuthReturnTo('/?enterprise=1&email=private@example.com', origin)).toBe(`${origin}/organization-access`)
  expect(safeAuthReturnTo('https://evil.test/organization-access', origin)).toBe(`${origin}/`)
  window.history.replaceState(null, '', '/login?returnTo=%2Forganization-access')
  expect(authReturnState()).toEqual({ returnTo: `${window.location.origin}/organization-access` })
})
