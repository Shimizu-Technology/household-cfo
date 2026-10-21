// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { scheduleFirstSessionComposerFocus } from './components/firstSessionComposerFocus'

beforeEach(() => { vi.useFakeTimers() })
afterEach(() => { cleanup(); vi.useRealTimers() })
function setup() {
  render(<div><button>Choose setup prompt</button><button>Context and help</button><textarea aria-label="Ask Mia" /></div>)
  const origin = screen.getByRole('button', { name: 'Choose setup prompt' })
  const composer = screen.getByRole('textbox', { name: 'Ask Mia' }) as HTMLTextAreaElement
  act(() => origin.focus())
  return { origin, composer }
}
it('focuses the composer after a setup prompt closes its originating panel', () => {
  const { origin, composer } = setup()
  scheduleFirstSessionComposerFocus(() => composer, () => true)
  origin.remove()
  act(() => vi.advanceTimersByTime(80))
  expect(document.activeElement).toBe(composer)
})
it('preserves a chat menu control selected before the delayed composer focus', () => {
  const { composer } = setup()
  scheduleFirstSessionComposerFocus(() => composer, () => true)
  const context = screen.getByRole('button', { name: 'Context and help' })
  act(() => context.focus())
  act(() => vi.advanceTimersByTime(80))
  expect(document.activeElement).toBe(context)
})
it('yields to a touch press even when Safari leaves DOM focus on the earlier trigger', () => {
  const { origin, composer } = setup()
  scheduleFirstSessionComposerFocus(() => composer, () => true)
  fireEvent.pointerDown(screen.getByRole('button', { name: 'Context and help' }))
  act(() => vi.advanceTimersByTime(80))
  expect(document.activeElement).toBe(origin)
})
it('does not focus a departed chat after the participant navigates away', () => {
  const { origin, composer } = setup()
  let active = true
  scheduleFirstSessionComposerFocus(() => composer, () => active)
  active = false
  origin.remove()
  act(() => vi.advanceTimersByTime(80))
  expect(document.activeElement).toBe(document.body)
})
