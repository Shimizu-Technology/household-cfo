// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { dialogExit } from './dialogExit'

let finishAnimation: () => void
beforeEach(() => {
  vi.useFakeTimers()
  vi.stubGlobal('CSS', { supports: () => true })
  vi.stubGlobal('matchMedia', () => ({ matches: false }))
  window.matchMedia = () => ({ matches: false }) as MediaQueryList
  Object.defineProperty(HTMLElement.prototype, 'inert', { configurable: true, writable: true, value: false })
  Object.defineProperty(HTMLElement.prototype, 'animate', { configurable: true, value: vi.fn(() => {
    const finished = new Promise<void>(resolve => { finishAnimation = resolve })
    return { finished, cancel: vi.fn() }
  }) })
  document.body.innerHTML = '<div data-dialog-surface><section data-dialog-panel style="transition-duration: 0.15s"><textarea>Initial</textarea><input type="checkbox"><select><option>One</option><option>Two</option></select><div class="scroll"></div></section></div><button id="page">Page</button>'
})
afterEach(() => {
  document.body.innerHTML = ''; vi.useRealTimers(); vi.unstubAllGlobals(); vi.restoreAllMocks()
  delete (HTMLElement.prototype as { inert?: boolean }).inert
  delete (HTMLElement.prototype as { animate?: unknown }).animate
})
const panel = () => document.querySelector<HTMLElement>('section')!
const close = () => document.querySelector('[data-dialog-surface]')!.remove()
const copy = () => document.querySelector<HTMLElement>('[data-dialog-exit-copy]')

it('calls the owner synchronously even when animations never finish', () => {
  const done = vi.fn(close)
  dialogExit(panel(), done)
  expect(done).toHaveBeenCalledOnce()
  expect(copy()).not.toBeNull()
  vi.advanceTimersByTime(200)
  expect(copy()).toBeNull()
  expect(done).toHaveBeenCalledOnce()
})
it('copies current typed, checked, selected and nested scroll state without handlers or IDs', () => {
  const field = document.querySelector('textarea')!, check = document.querySelector('input')!, select = document.querySelector('select')!, scroller = document.querySelector<HTMLElement>('.scroll')!
  field.value = 'My unsaved correction'; field.id = 'draft'; field.setAttribute('onfocus', 'throw new Error()')
  check.checked = true; check.indeterminate = true; select.selectedIndex = 1
  scroller.scrollTop = 42; scroller.scrollLeft = 15; panel().scrollTop = 23
  dialogExit(panel(), close)
  expect(copy()?.querySelector('textarea')?.value).toBe('My unsaved correction')
  expect(copy()?.querySelector('input')?.checked).toBe(true)
  expect(copy()?.querySelector('input')?.indeterminate).toBe(true)
  expect(copy()?.querySelector('select')?.selectedIndex).toBe(1)
  expect(copy()?.querySelector<HTMLElement>('.scroll')?.scrollTop).toBe(42)
  expect(copy()?.querySelector<HTMLElement>('.scroll')?.scrollLeft).toBe(15)
  expect(copy()?.querySelector<HTMLElement>('section')?.scrollTop).toBe(23)
  expect(copy()?.querySelector('[id], [onfocus]')).toBeNull()
  expect(copy()?.inert).toBe(true)
  expect(copy()?.getAttribute('aria-hidden')).toBe('true')
  expect(copy()?.style.pointerEvents).toBe('none')
})
it('does not fade or disable a guarded panel and allows the next close attempt', () => {
  const node = panel(), denied = vi.fn()
  dialogExit(node, denied)
  expect(denied).toHaveBeenCalledOnce()
  expect(copy()).toBeNull()
  expect(node.dataset.dialogClosing).toBeUndefined()
  dialogExit(node, close)
  expect(copy()).not.toBeNull()
})
it.each(['data-dialog-private', 'media', 'password', 'background image', 'SVG image'])('never copies %s content', kind => {
  if (kind === 'data-dialog-private') panel().setAttribute(kind, '')
  if (kind === 'media') panel().append(document.createElement('img'))
  if (kind === 'password') document.querySelector('input')!.type = 'password'
  if (kind === 'background image') panel().style.backgroundImage = 'url(blob:private-image)'
  if (kind === 'SVG image') panel().innerHTML = '<svg><image href="blob:private-image" /></svg>'
  dialogExit(panel(), close)
  expect(copy()).toBeNull()
})
it('dismisses instantly without browser animation support or loaded CSS', () => {
  panel().style.transitionDuration = ''
  const done = vi.fn(close)
  dialogExit(panel(), done)
  expect(done).toHaveBeenCalledOnce()
  expect(copy()).toBeNull()
})
it('keeps only one copy and removes it when all animations finish, before the deadline', async () => {
  // Both animations share one completion to model a browser finishing the exit.
  const finished = new Promise<void>(resolve => { finishAnimation = resolve })
  vi.mocked(HTMLElement.prototype.animate).mockReturnValue({ finished, cancel: vi.fn() } as unknown as Animation)
  const node = panel(), done = vi.fn(close)
  const cancel = dialogExit(node, done)
  expect(dialogExit(node, done)).toBe(cancel)
  expect(document.querySelectorAll('[data-dialog-exit-copy]')).toHaveLength(1)
  finishAnimation(); await vi.advanceTimersByTimeAsync(0)
  expect(copy()).toBeNull()
  expect(done).toHaveBeenCalledOnce()
  vi.advanceTimersByTime(500)
  expect(done).toHaveBeenCalledOnce()
})
it('reduced motion animates opacity without movement', () => {
  window.matchMedia = () => ({ matches: true }) as MediaQueryList
  panel().style.transform = 'none'
  dialogExit(panel(), close)
  const frames = vi.mocked(HTMLElement.prototype.animate).mock.calls[0][0] as Keyframe[]
  expect(frames[0].transform).toBe(frames[1].transform)
  expect(frames[1].opacity).toBe(0)
})

it('keeps a replacement dialog above the departing visual in the original sibling slot', () => {
  const next = document.createElement('div')
  next.setAttribute('data-next-dialog', '')
  dialogExit(panel(), () => { close(); document.body.prepend(next) })
  expect(copy()?.nextElementSibling).toBe(next)
})

it('does not require a native dialog constructor in a browser without that global', () => {
  vi.stubGlobal('HTMLDialogElement', undefined)
  const done = vi.fn(close)
  dialogExit(panel(), done)
  expect(done).toHaveBeenCalledOnce()
})
it('native dialogs close synchronously without copying their live content', () => {
  document.body.innerHTML = '<div data-dialog-surface><dialog style="transition-duration: 0.15s">Private native content</dialog></div>'
  const done = vi.fn(close)
  dialogExit(document.querySelector('dialog'), done)
  expect(done).toHaveBeenCalledOnce()
  expect(copy()).toBeNull()
})


it('finishes descendant entry animations without stripping their fill styles', () => {
  const scrim = document.createElement('div')
  scrim.className = 'scrim'
  scrim.style.animationName = 'entry'
  scrim.style.animationDuration = '220ms'
  scrim.style.animationDelay = '100ms'
  scrim.style.animationFillMode = 'both'
  panel().before(scrim)
  dialogExit(panel(), close)
  const copiedScrim = copy()?.querySelector<HTMLElement>('.scrim')
  expect(copiedScrim?.style.animationName).toBe('entry')
  expect(copiedScrim?.style.animationFillMode).toBe('both')
  expect(copiedScrim?.style.animationDuration).toBe('0s')
  expect(copiedScrim?.style.animationDelay).toBe('0s')
})
