// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { AuthPopupComplete } from './AuthPopupComplete'
import { AUTH_POPUP_MESSAGE } from '../lib/authPopup'
afterEach(() => { cleanup(); vi.unstubAllGlobals() })
it('signals only completion to the same-origin opener and never sends credentials', () => {
  const postMessage = vi.fn(); const close = vi.fn()
  vi.stubGlobal('opener', { postMessage }); vi.stubGlobal('close', close)
  render(<AuthPopupComplete />)
  expect(postMessage).toHaveBeenCalledWith({ type: AUTH_POPUP_MESSAGE }, window.location.origin)
  expect(close).toHaveBeenCalledOnce()
})
it('keeps a usable app return when the provider separates the opener', () => {
  vi.stubGlobal('opener', null)
  render(<AuthPopupComplete />)
  expect(screen.getByRole('link', { name: 'Return to Household CFO' }).getAttribute('href')).toBe('/')
})
it('uses a fixed error marker instead of sending private error detail', () => {
  const postMessage = vi.fn()
  vi.stubGlobal('opener', { postMessage }); vi.stubGlobal('close', vi.fn())
  render(<AuthPopupComplete error="Sign-in was canceled. You can try again when you’re ready." />)
  expect(postMessage).toHaveBeenCalledWith({ type: AUTH_POPUP_MESSAGE, error: 'cancelled' }, window.location.origin)
})
