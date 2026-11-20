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

const account = (id: number, label: string, choice: boolean | 'all_in' | null = null, extra: object = {}) => ({ source_account_id: id, label, account_basis: 'asset', single_sign: false, choice, answerable: true, lines: choice === null ? 0 : 3, effect: choice === null ? null : `You said spending in ${label} is shown as negative. That set the direction of 3 lines.`, ...extra })
const accountState = (questions: object[]) => ({ needBasis: [], plan: { signed_amount_question: questions.some(question => (question as { choice: unknown }).choice === null), account_sign_questions: questions }, answerSign: vi.fn() }) as unknown as ComponentProps<typeof StatementSignQuestion>['state']
it('asks a multi-account file once per account, the next unanswered account first', () => {
  const model = accountState([account(11, 'Talun checking ····4410', true), account(12, 'Talun card ····6074'), account(13, 'Talun savings ····8642', null, { single_sign: true })])
  render(<StatementSignQuestion state={model} />)
  expect(screen.getByText('Account 2 of 3')).toBeTruthy()
  expect(document.querySelector('[data-sign-next]')?.textContent).toBe('In Talun card ····6074, is money you spent shown as a negative amount (with a minus sign or parentheses)?')
  expect(screen.getByRole('status').textContent).toBe('You said spending in Talun checking ····4410 is shown as negative. That set the direction of 3 lines.')
  // Changing an earlier answer waits until every account has one.
  expect(screen.queryByRole('button', { name: 'Change Talun checking ····4410' })).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: 'No, spending is positive' }))
  expect(model.answerSign).toHaveBeenCalledWith(false, 12)
})
it('asks an account whose amounts share one sign whether they are all in or all out', () => {
  const model = accountState([account(11, 'Talun checking ····4410', true), account(13, 'Talun savings ····8642', null, { single_sign: true })])
  render(<StatementSignQuestion state={model} />)
  expect(document.querySelector('[data-sign-next]')?.textContent).toBe('Every amount in Talun savings ····8642 is shown the same way. Is it all money out, all money in, or a mix?')
  fireEvent.click(screen.getByRole('button', { name: 'All money in' }))
  expect(model.answerSign).toHaveBeenCalledWith('all_in', 13)
})
it('lets her change one account after every account is answered, and only while nothing is approved', () => {
  const model = accountState([account(11, 'Talun checking ····4410', true), account(12, 'Talun card ····6074', true)])
  render(<StatementSignQuestion state={model} />)
  expect(screen.getByRole('status').textContent).toBe('You answered money in or out for 2 accounts. That set the direction of 6 lines.')
  fireEvent.click(screen.getByText('See or change each account'))
  expect(screen.getByText('You said spending in Talun checking ····4410 is shown as negative. That set the direction of 3 lines.')).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: 'Change Talun card ····6074' }))
  expect(document.activeElement?.textContent).toBe('In Talun card ····6074, is money you spent shown as a negative amount (with a minus sign or parentheses)?')
  fireEvent.click(screen.getByRole('button', { name: 'I’m not sure' }))
  expect(model.answerSign).toHaveBeenCalledWith('individual', 12)
  cleanup()
  render(<StatementSignQuestion state={accountState([account(11, 'Talun checking ····4410', true, { answerable: false }), account(12, 'Talun card ····6074', true, { answerable: false })])} />)
  expect(screen.getByRole('status').textContent).toBe('You answered money in or out for 2 accounts. That set the direction of 6 lines.')
  expect(screen.getByText('See each account')).toBeTruthy()
  expect(screen.queryByRole('button')).toBeNull()
})
