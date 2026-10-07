// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest'
import { AUTH_POPUP_MESSAGE, navigateAuthPopup, openAuthPopup, watchAuthPopup } from './authPopup'
import type { BrowserAuthSession } from './browserAuthSession'
const session = { client_id: 'client_FICTIONAL', user: { id: 'user_FICTIONAL', email: 'fictional@pilot.test', first_name: null, last_name: null }, access_token: 'new-token', expires_at: new Date(Date.now() + 60_000).toISOString(), organization_id: null, authentication_method: 'GoogleOAuth' } satisfies BrowserAuthSession
const popup = () => ({ close: vi.fn(), closed: false, location: { href: 'about:blank' } }) as unknown as Window
const send = (source: Window, origin = window.location.origin, data: unknown = { type: AUTH_POPUP_MESSAGE }) => window.dispatchEvent(new MessageEvent('message', { origin, source, data }))
afterEach(() => { vi.unstubAllGlobals(); vi.useRealTimers() })
it('opens synchronously on desktop and falls back on phones or blocked windows', () => {
  const open = vi.fn().mockReturnValue(null); vi.stubGlobal('open', open)
  vi.stubGlobal('matchMedia', () => ({ matches: false }))
  expect(openAuthPopup()).toBeNull(); expect(open).not.toHaveBeenCalled()
  vi.stubGlobal('matchMedia', () => ({ matches: true }))
  expect(openAuthPopup()).toBeNull(); expect(open).toHaveBeenCalledOnce()
})
it('ignores forged origin and unrelated window and reads authoritative cookie before completion', async () => {
  const own = popup(); const read = vi.fn().mockResolvedValue(session)
  const result = watchAuthPopup(own, read, undefined, new AbortController().signal)
  send(own, 'https://attacker.test'); send(popup())
  expect(read).not.toHaveBeenCalled()
  send(own)
  expect(await result).toEqual(session); expect(own.close).toHaveBeenCalledOnce()
})
it('does not accept a completion message without an authoritative session', async () => {
  const own = popup(); const result = watchAuthPopup(own, vi.fn().mockResolvedValue(null), undefined, new AbortController().signal)
  const rejected = expect(result).rejects.toThrow('Sign-in could not finish')
  send(own); await rejected
})
it('handles cancellation and closes only its own authentication window', async () => {
  const own = popup(); const controller = new AbortController()
  const result = watchAuthPopup(own, vi.fn(), undefined, controller.signal)
  const rejected = expect(result).rejects.toThrow('Sign-in was canceled')
  controller.abort(); await rejected; expect(own.close).toHaveBeenCalledOnce()
})
it('rejects untrusted popup authorization destinations', () => {
  const own = popup()
  expect(() => navigateAuthPopup(own, 'https://attacker.test')).toThrow()
  expect(own.location.href).toBe('about:blank')
})
