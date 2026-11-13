// @vitest-environment jsdom
import { act, cleanup, fireEvent, render } from '@testing-library/react'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { useLayoutEffect, useState } from 'react'
import { usePilotDialog } from './usePilotDialog'

let frames: Map<number, FrameRequestCallback>
let nextFrame: number
beforeEach(() => {
  frames = new Map(); nextFrame = 0
  vi.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => { frames.set(++nextFrame, callback); return nextFrame })
  vi.spyOn(window, 'cancelAnimationFrame').mockImplementation(id => { frames.delete(id) })
})
afterEach(() => { cleanup(); document.body.innerHTML = ''; vi.restoreAllMocks(); vi.unstubAllGlobals(); vi.useRealTimers() })
function Probe() {
  const { dialogRef: ref } = usePilotDialog(() => {})
  return <section ref={ref} role="dialog" tabIndex={-1}><header><button>Close</button></header><div className="pilot-dialog-body"><textarea aria-label="Early feedback" /></div></section>
}
function box(element: HTMLElement, top: number, height: number) {
  vi.spyOn(element, 'getBoundingClientRect').mockReturnValue({ top, bottom: top + height, height } as DOMRect)
  Object.defineProperty(element, 'clientHeight', { configurable: true, value: height })
}
function flushFrames() {
  act(() => { const pending = [...frames.values()]; frames.clear(); pending.forEach(callback => callback(0)) })
}
test('opening frame preserves an early focused field, typed value and its scrolling body', () => {
  const view = render(<Probe />), dialog = view.getByRole('dialog'), field = view.getByLabelText('Early feedback') as HTMLTextAreaElement
  const body = field.closest<HTMLElement>('.pilot-dialog-body')!
  box(dialog, 10, 300); box(body, 80, 230)
  vi.spyOn(field, 'getBoundingClientRect').mockImplementation(() => ({ top: 500 - body.scrollTop, bottom: 544 - body.scrollTop, height: 44 } as DOMRect))
  body.scrollTop = 150; dialog.scrollTop = 63
  field.focus(); fireEvent.change(field, { target: { value: 'Fictional early feedback' } })
  expect(document.activeElement).toBe(field)
  expect(body.scrollTop).toBe(234)
  flushFrames()
  expect(document.activeElement).toBe(field)
  expect(field.value).toBe('Fictional early feedback')
  expect(body.scrollTop).toBe(234)
  expect(dialog.scrollTop).toBe(63)
})
test('opening frame still focuses Close and resets outer scrolling when focus starts outside', () => {
  const opener = document.createElement('button'); document.body.append(opener); opener.focus()
  const view = render(<Probe />), dialog = view.getByRole('dialog'), close = view.getByRole('button', { name: 'Close' })
  box(dialog, 10, 300); box(close, 20, 44)
  dialog.scrollTop = 63
  flushFrames()
  expect(document.activeElement).toBe(close)
  expect(dialog.scrollTop).toBe(0)
})
test('unmount cancels pending opening focus and restores the opener and page scrolling', () => {
  const opener = document.createElement('button'); document.body.append(opener); opener.focus()
  const previousOverflow = document.body.style.overflow
  const view = render(<Probe />)
  expect(frames.size).toBe(1)
  expect(document.body.style.overflow).toBe('hidden')
  view.unmount()
  expect(window.cancelAnimationFrame).toHaveBeenCalledWith(1)
  expect(frames.size).toBe(0)
  flushFrames()
  expect(document.activeElement).toBe(opener)
  expect(document.body.style.overflow).toBe(previousOverflow)
})
test('page scrolling stays locked until the last stacked dialog closes, whichever closes first', () => {
  document.body.style.overflow = 'scroll'
  const underneath = render(<Probe />)
  const confirmation = render(<Probe />)
  expect(document.body.style.overflow).toBe('hidden')
  // The dialog underneath goes away while the confirmation over it is still open.
  underneath.unmount()
  expect(document.body.style.overflow).toBe('hidden')
  confirmation.unmount()
  expect(document.body.style.overflow).toBe('scroll')
  document.body.style.overflow = ''
})
test('closing the topmost dialog keeps the page locked for the one underneath', () => {
  const underneath = render(<Probe />)
  const confirmation = render(<Probe />)
  confirmation.unmount()
  expect(document.body.style.overflow).toBe('hidden')
  underneath.unmount()
  expect(document.body.style.overflow).toBe('')
})


test('returns to a disclosure summary when its opening action became hidden', () => {
  const details = document.createElement('details')
  details.open = true
  details.innerHTML = '<summary tabindex="0">Account and help</summary><button>Guide</button>'
  document.body.append(details)
  details.querySelector('button')!.focus()
  const view = render(<Probe />)
  flushFrames()
  details.open = false
  view.unmount()
  expect(document.activeElement).toBe(details.querySelector('summary'))
})

test('releases the focus trap and scroll lock before the parent restores focus', () => {
  const restored = vi.fn()
  function Dialog({ onClose }: { onClose: () => void }) {
    const { dialogRef, requestClose } = usePilotDialog(onClose)
    return <section ref={dialogRef} role="dialog"><button onClick={requestClose}>Dismiss</button></section>
  }
  function Parent() {
    const [open, setOpen] = useState(true)
    useLayoutEffect(() => {
      if (!open) restored(document.body.style.overflow)
    }, [open])
    return open ? <Dialog onClose={() => setOpen(false)} /> : null
  }
  const view = render(<Parent />)
  expect(document.body.style.overflow).toBe('hidden')
  fireEvent.click(view.getByRole('button', { name: 'Dismiss' }))
  expect(restored).toHaveBeenCalledWith('')
})
