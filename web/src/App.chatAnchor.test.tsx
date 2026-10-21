// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { createRef } from 'react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { useMiaEntryAnchor } from './components/useMiaEntryAnchor'

let frames: FrameRequestCallback[]
let resize: ResizeObserverCallback
const disconnect = vi.fn()

beforeEach(() => {
  vi.useFakeTimers()
  frames = []
  vi.stubGlobal('requestAnimationFrame', vi.fn(callback => { frames.push(callback); return frames.length }))
  vi.stubGlobal('cancelAnimationFrame', vi.fn())
  vi.stubGlobal('ResizeObserver', class {
    constructor(callback: ResizeObserverCallback) { resize = callback }
    observe = vi.fn()
    disconnect = disconnect
  })
})
afterEach(() => { cleanup(); vi.useRealTimers(); vi.unstubAllGlobals(); vi.resetAllMocks() })

function setup() {
  const chatRef = createRef<HTMLDivElement>()
  const awayRef = { current: false }
  const anchor = vi.fn()
  const setShowScrollButton = vi.fn()
  function History() {
    useMiaEntryAnchor({ active: true, messageKey: 'latest', loading: false, chatRef, awayRef, anchor, setShowScrollButton })
    return <div ref={chatRef}><button>Load earlier messages</button><img alt="Receipt" /></div>
  }
  return { ...render(<History />), awayRef, anchor, setShowScrollButton }
}

it('yields to a pointer press before a late entry frame, image load or resize can move its target', () => {
  const { anchor, awayRef } = setup()
  fireEvent.pointerDown(screen.getByRole('button', { name: 'Load earlier messages' }))
  act(() => {
    frames.forEach(frame => frame(0))
    resize([], {} as ResizeObserver)
  })
  fireEvent.load(screen.getByRole('img'))
  expect(awayRef.current).toBe(true)
  expect(anchor).not.toHaveBeenCalled()
})

it('anchors an untouched reply while it settles, then stops observing on departure', () => {
  const { anchor, setShowScrollButton, awayRef, unmount } = setup()
  const button = screen.getByRole('button')
  act(() => { frames.forEach(frame => frame(0)); resize([], {} as ResizeObserver) })
  expect(anchor).toHaveBeenCalledTimes(2)
  expect(setShowScrollButton).toHaveBeenCalledWith(false)
  act(() => vi.advanceTimersByTime(2500))
  act(() => resize([], {} as ResizeObserver))
  expect(anchor).toHaveBeenCalledTimes(2)
  unmount()
  act(() => resize([], {} as ResizeObserver))
  fireEvent.pointerDown(button)
  expect(disconnect).toHaveBeenCalledTimes(1)
  expect(awayRef.current).toBe(false)
  expect(anchor).toHaveBeenCalledTimes(2)
})
