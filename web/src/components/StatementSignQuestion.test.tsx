// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import type { ComponentProps } from 'react'
import { StatementSignQuestion } from './StatementSignQuestion'

afterEach(cleanup)
const state = (effect?: string, answerable = true) => ({ needBasis: [], plan: { signed_amount_question: !effect, signed_amount_answerable: answerable, sign_effect: effect }, answerSign: vi.fn() }) as unknown as ComponentProps<typeof StatementSignQuestion>['state']
it('asks the unanswered question', () => {
  render(<StatementSignQuestion state={state()} />)
  expect(screen.getByRole('button', { name: 'Yes, spending is negative' })).toBeTruthy()
  expect(screen.queryByRole('button', { name: 'Change this' })).toBeNull()
})
for (const effect of ['You said spending is shown as negative. That set the direction of 10 lines.', 'The balance column shows spending as negative. That set the direction of 10 lines.', 'You chose to answer money out or money in for each line.']) it(`discloses an optional change after ${effect}`, () => {
  const model = state(effect)
  render(<StatementSignQuestion state={model} />)
  expect(screen.getByRole('status').textContent).toBe(effect)
  expect(screen.queryByRole('button', { name: 'Yes, spending is negative' })).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: 'Change this' }))
  expect(document.activeElement?.className).toBe('statement-question')
  fireEvent.click(screen.getByRole('button', { name: 'Yes, spending is negative' }))
  expect(model.answerSign).toHaveBeenCalledWith(true)
})
it('offers no whole-file change after a saved decision', () => {
  render(<StatementSignQuestion state={state('You chose to answer money out or money in for each line.', false)} />)
  expect(screen.queryByRole('button')).toBeNull()
})
