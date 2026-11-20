// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import type { LineKind } from '../lib/statementReview'
import { participantReviewFixture } from '../../e2e/sourceReviewFixtures'
import { StatementAccountSheet, StatementLineSheet } from './StatementSheets'

afterEach(cleanup)

function openSheet(kind: LineKind) {
  const onSave = vi.fn()
  render(<StatementLineSheet line={{ directionRequired: true, eventId: 1, kind, merchant: 'Payless', postedOn: '2026-10-01', amountCents: 1_000, categoryId: null, leftOut: false }} categories={[]} busy={false} error={null} onSave={onSave} onLeaveOut={vi.fn()} onClose={vi.fn()} />)
  return onSave
}

it('does not save a line with no direction, and keeps the amount it opened with', () => {
  const onSave = openSheet('moved')
  expect((screen.getByLabelText('Amount') as HTMLInputElement).value).toBe('10.00')
  fireEvent.click(screen.getByRole('button', { name: 'Save' }))
  expect(screen.getByRole('alert').textContent).toBe('Choose whether this was money out or money in.')
  expect(onSave).not.toHaveBeenCalled()
})

// The server refuses a refund that is money out, and spending or cash that is money in.
it.each([
  ['refund', 'Money out', 'spending', 'out'],
  ['refund', 'Money in', 'refund', 'in'],
  ['cash', 'Money in', 'money_in', 'in'],
  ['cash', 'Money out', 'cash', 'out'],
  ['moved', 'Money in', 'moved', 'in'],
] as const)('a %s line answered %s is saved as %s', (kind, answer, savedKind, direction) => {
  const onSave = openSheet(kind)
  fireEvent.click(screen.getByRole('button', { name: answer }))
  fireEvent.click(screen.getByRole('button', { name: 'Save' }))
  expect(onSave).toHaveBeenCalledWith(expect.objectContaining({ kind: savedKind, money_direction: direction, amount_cents: 1_000 }))
})

// A cash withdrawal is spending until she says it moved between her accounts.
it('saves a withdrawal with a chosen category and clears it when changed to moved money', () => {
  const onSave = vi.fn()
  render(<StatementLineSheet line={{ eventId: 1, kind: 'cash', merchant: 'Tasi Demo ATM', postedOn: '2026-10-04', amountCents: 8000, categoryId: null, leftOut: false }} categories={[{ id: 7, name: 'Cash' }]} busy={false} error={null} onSave={onSave} onLeaveOut={vi.fn()} onClose={vi.fn()} />)
  expect(screen.getByText('Without a category, this won’t count toward your spending.')).toBeTruthy()
  fireEvent.change(screen.getByRole('combobox', { name: /^Category/ }), { target: { value: '7' } })
  fireEvent.click(screen.getByRole('button', { name: 'Save' }))
  expect(onSave).toHaveBeenLastCalledWith(expect.objectContaining({ kind: 'cash', category_id: 7, amount_cents: 8000 }))
  fireEvent.change(screen.getByLabelText('What was this?'), { target: { value: 'moved' } })
  expect(screen.queryByRole('combobox', { name: /^Category/ })).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: 'Save' }))
  expect(onSave).toHaveBeenLastCalledWith(expect.objectContaining({ kind: 'moved', category_id: null }))
})

it('can choose a different saved account or explicitly save a new one', () => {
  const fixture = participantReviewFixture()
  const row = fixture.participant_review!.accounts[0]
  const proposed = { id: 10, name: 'Bank of Hawaii', last4: '6824', account_basis: 'asset' } as const
  const other = { id: 11, name: 'Everyday checking', last4: '8899', account_basis: 'asset' } as const
  const onSave = vi.fn()
  render(<StatementAccountSheet accounts={fixture.accounts} reviewed={[{ ...row, approved: null, suggested: proposed, choices: [proposed, other] }]} names={{}} busy={false} error={null} onSave={onSave} onClose={vi.fn()} />)
  const account = screen.getByRole('combobox', { name: 'Account' })
  expect((account as HTMLSelectElement).value).toBe('10')
  fireEvent.change(account, { target: { value: '11' } })
  fireEvent.click(screen.getByRole('button', { name: 'Save' }))
  expect(onSave).toHaveBeenLastCalledWith([expect.objectContaining({ tracked_account_id: 11 })])
  fireEvent.change(account, { target: { value: 'new' } })
  fireEvent.click(screen.getByRole('button', { name: 'Save' }))
  expect(onSave).toHaveBeenLastCalledWith([expect.objectContaining({ tracked_account_id: null })])
})

it.each([['moved', 'Your own account'], ['spending', 'Someone else']] as const)('a person payment with missing direction requires an explicit %s answer', (kind, label) => {
  const onSave = vi.fn()
  render(<StatementLineSheet line={{ recipientQuestion: true, directionRequired: true, moneyDirection: 'out', eventId: 1, kind: 'spending', merchant: 'Zelle to Lina Talun', postedOn: '2026-07-08', amountCents: 3500, categoryId: null, leftOut: false }} categories={[]} busy={false} error={null} onSave={onSave} onLeaveOut={vi.fn()} onClose={vi.fn()} />)
  const recipient = screen.getByRole('button', { name: label })
  expect(recipient.getAttribute('aria-pressed')).toBe('false')
  fireEvent.click(screen.getByRole('button', { name: 'Save' }))
  expect(onSave).not.toHaveBeenCalled()
  fireEvent.click(recipient)
  expect(recipient.getAttribute('aria-pressed')).toBe('true')
  fireEvent.click(screen.getByRole('button', { name: 'Save' }))
  expect(onSave).toHaveBeenCalledWith(expect.objectContaining({ kind, money_direction: 'out', amount_cents: 3500, category_id: null }))
})

it('changing a person payment from money in to money out asks ownership before saving', () => {
  const onSave = vi.fn()
  render(<StatementLineSheet line={{ recipientQuestion: true, directionRequired: true, moneyDirection: 'in', eventId: 1, kind: 'money_in', merchant: 'Zelle to Lina Talun', postedOn: '2026-07-08', amountCents: 3500, categoryId: null, leftOut: false }} categories={[]} busy={false} error={null} onSave={onSave} onLeaveOut={vi.fn()} onClose={vi.fn()} />)
  fireEvent.click(screen.getByRole('button', { name: 'Money out' }))
  expect(screen.getByRole('button', { name: 'Your own account' }).getAttribute('aria-pressed')).toBe('false')
  expect(screen.getByRole('button', { name: 'Someone else' }).getAttribute('aria-pressed')).toBe('false')
  fireEvent.click(screen.getByRole('button', { name: 'Save' }))
  expect(onSave).not.toHaveBeenCalled()
  expect(screen.getByRole('alert').textContent).toBe('Choose your own account or someone else.')
})
