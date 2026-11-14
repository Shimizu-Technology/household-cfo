// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react'
import { createRef } from 'react'
import { afterEach, expect, it, vi } from 'vitest'
import { MiaCardResult } from './MiaCardResult'
afterEach(cleanup)
it('focuses an inert visible result heading outside the disclosure control', () => {
  const heading = createRef<HTMLHeadingElement>()
  render(<MiaCardResult title="Saved to today" headingRef={heading} onDone={vi.fn()}><p>Saved details</p></MiaCardResult>)
  heading.current?.focus()
  expect(document.activeElement).toBe(screen.getByRole('heading', { name: 'Saved to today' }))
  expect(heading.current?.closest('summary')).toBeNull()
  expect(heading.current?.closest('details')).toBeNull()
})

it('fix2 exposes the completion line silently when restoring history', () => {
  render(<MiaCardResult title="Saved to today" status="Saved details" onDone={vi.fn()} />)
  const status = screen.getByRole('status')
  expect(status.closest('details')).toBeNull()
  expect(status.getAttribute('aria-live')).toBe('off')
  expect(document.activeElement).toBe(document.body)
})

it('announces a live completion and never focuses the Done action', () => {
  render(<MiaCardResult title="Saved to today" status="Your spending is up to date." live onDone={vi.fn()} />)
  expect(screen.getByRole('status').getAttribute('aria-live')).toBe('polite')
  expect(document.activeElement).toBe(screen.getByRole('heading', { name: 'Saved to today' }))
})
