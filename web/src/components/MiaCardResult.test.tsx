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
