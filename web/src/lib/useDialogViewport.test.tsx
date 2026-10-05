// @vitest-environment jsdom
import { act, render } from '@testing-library/react'
import { afterEach, expect, test, vi } from 'vitest'
import { useDialogViewport } from './useDialogViewport'

function Probe() { useDialogViewport(); return null }
afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks() })

test('dialog viewport follows keyboard resize and pan, preserves pinch zoom, and restores owned styles', () => {
  const viewport = Object.assign(new EventTarget(), { height: 660, offsetTop: 0, scale: 1 })
  vi.stubGlobal('visualViewport', viewport)
  vi.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => { callback(0); return 1 })
  vi.spyOn(window, 'cancelAnimationFrame').mockImplementation(() => {})
  const style = document.documentElement.style
  style.setProperty('--dialog-viewport-height', '700px')
  const mounted = render(<Probe />)
  expect(style.getPropertyValue('--dialog-viewport-height')).toBe('660px')
  act(() => { viewport.height = 320; viewport.offsetTop = 70; viewport.dispatchEvent(new Event('resize')); viewport.dispatchEvent(new Event('scroll')) })
  expect(style.getPropertyValue('--dialog-viewport-height')).toBe('320px')
  expect(style.getPropertyValue('--dialog-viewport-top')).toBe('70px')
  act(() => { viewport.scale = 2; viewport.height = 160; viewport.dispatchEvent(new Event('resize')) })
  expect(style.getPropertyValue('--dialog-viewport-height')).toBe('320px')
  act(() => { viewport.scale = 1; viewport.height = 660; viewport.offsetTop = 0; viewport.dispatchEvent(new Event('resize')) })
  expect(style.getPropertyValue('--dialog-viewport-height')).toBe('660px')
  mounted.unmount()
  expect(style.getPropertyValue('--dialog-viewport-height')).toBe('700px')
  expect(style.getPropertyValue('--dialog-viewport-top')).toBe('')
  viewport.height = 100
  viewport.dispatchEvent(new Event('resize'))
  expect(style.getPropertyValue('--dialog-viewport-height')).toBe('700px')
  style.removeProperty('--dialog-viewport-height')
})

test('browsers without VisualViewport keep the CSS dynamic viewport fallback', () => {
  vi.stubGlobal('visualViewport', undefined)
  const mounted = render(<Probe />)
  expect(document.documentElement.style.getPropertyValue('--dialog-viewport-height')).toBe('')
  mounted.unmount()
})


test('a keyboard resize reveals the active dialog field without moving focus', () => {
  const viewport = Object.assign(new EventTarget(), { height: 660, offsetTop: 0, scale: 1 })
  vi.stubGlobal('visualViewport', viewport)
  vi.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => { callback(0); return 1 })
  vi.spyOn(window, 'cancelAnimationFrame').mockImplementation(() => {})
  const mounted = render(<><Probe /><section role="dialog"><textarea aria-label="Fictional field" /></section></>)
  const dialog = mounted.getByRole('dialog')
  const field = mounted.getByLabelText('Fictional field')
  vi.spyOn(dialog, 'getBoundingClientRect').mockReturnValue({ top: 12, bottom: 308 } as DOMRect)
  vi.spyOn(field, 'getBoundingClientRect').mockReturnValue({ top: 350, bottom: 480 } as DOMRect)
  const reveal = vi.fn()
  Object.defineProperty(field, 'scrollIntoView', { configurable: true, value: reveal })
  field.focus()
  act(() => { viewport.height = 320; viewport.dispatchEvent(new Event('resize')) })
  expect(reveal).toHaveBeenCalledWith({ block: 'nearest', inline: 'nearest' })
  expect(document.activeElement).toBe(field)
  mounted.unmount()
})
