// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { CashPurchaseQuestion } from '../api'
import { CashPurchaseQuestions } from './CashPurchaseQuestions'

const candidate = (id: number, label: string, amount: number) => ({
  financial_source_event_id: id, withdrawn_on: '2026-08-03', amount, amount_cents: amount * 100, available: amount, available_cents: amount * 100, covers_cents: 4000, label,
})

function question(overrides: Partial<CashPurchaseQuestion> = {}): CashPurchaseQuestion {
  return {
    transaction_draft_id: 310, transaction_id: 88, state: 'unanswered', merchant: 'Tasi Demo Cafe', occurred_on: '2026-08-05',
    amount: 40, amount_cents: 4000, cash_cents: 4000, covered_cents: 0, counting_on_its_own_cents: 4000,
    message: 'You paid $40 in cash. Right now it counts on its own, on top of the $100 you took out on Aug 3.',
    question: 'Paid with the $100 you took out on Aug 3?', candidates: [candidate(901, 'the $100 you took out on Aug 3', 100)], decline_label: 'No, other cash',
    ...overrides,
  }
}

describe('CashPurchaseQuestions', () => {
  beforeEach(() => { vi.useFakeTimers({ toFake: ['Date'] }); vi.setSystemTime(new Date('2026-08-06T12:00:00Z')) })
  afterEach(() => { cleanup(); vi.useRealTimers() })

  it('says what counts right now and asks which cash paid for a purchase she confirmed before the statement', async () => {
    const onAnswer = vi.fn().mockResolvedValue(undefined)
    const lunch = question()
    render(<CashPurchaseQuestions questions={[lunch]} onAnswer={onAnswer} />)

    expect(screen.getByRole('heading', { name: 'Paid with cash' })).toBeTruthy()
    expect(screen.getByText('You paid $40 in cash. Right now it counts on its own, on top of the $100 you took out on Aug 3.')).toBeTruthy()
    expect(screen.getByText('Paid with the $100 you took out on Aug 3?')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Yes: Tasi Demo Cafe on Aug 5 was paid with the $100 you took out on Aug 3' }))
    await waitFor(() => expect(onAnswer).toHaveBeenCalledWith(lunch, { cashWithdrawalEventId: 901 }))
    fireEvent.click(screen.getByRole('button', { name: 'No, other cash: Tasi Demo Cafe on Aug 5' }))
    await waitFor(() => expect(onAnswer).toHaveBeenCalledWith(lunch, { cashFromElsewhere: true }))
  })

  it('offers only to count it on its own when the cash it named is gone and nothing else is left', async () => {
    const onAnswer = vi.fn().mockResolvedValue(undefined)
    const dropped = question({ state: 'dropped', question: null, candidates: [], decline_label: 'Count it on its own',
      message: 'You said this was paid with cash you took out on Aug 3, but that withdrawal is no longer in your approved statements. Right now this $40 counts on its own.' })
    render(<CashPurchaseQuestions questions={[dropped]} onAnswer={onAnswer} errors={{ 'cash:310': 'Your answer could not be saved.' }} />)

    expect(screen.getByText(/no longer in your approved statements/)).toBeTruthy()
    expect(screen.getAllByRole('button').map(button => button.textContent)).toEqual(['Count it on its own'])
    expect(screen.getByRole('alert').textContent).toBe('Your answer could not be saved.')
    fireEvent.click(screen.getByRole('button', { name: 'Count it on its own: Tasi Demo Cafe on Aug 5' }))
    await waitFor(() => expect(onAnswer).toHaveBeenCalledWith(dropped, { cashFromElsewhere: true }))
  })

  it('names each withdrawal when several could have paid, and shows nothing when nothing is asked', () => {
    const several = question({ question: 'Which cash paid for this $40?', candidates: [candidate(902, 'the $100 you took out on Aug 3', 100), candidate(903, 'the $60 you took out on Jul 20', 60)] })
    const { rerender, container } = render(<CashPurchaseQuestions questions={[several]} onAnswer={vi.fn()} />)
    expect(screen.getByRole('button', { name: /paid with the \$60 you took out on Jul 20/ }).textContent).toBe('The $60 you took out on Jul 20')
    expect(screen.getByText('Your cash already counted when you took it out, so choosing it doesn’t add to your spending.')).toBeTruthy()
    rerender(<CashPurchaseQuestions questions={[]} onAnswer={vi.fn()} />)
    expect(container.textContent).toBe('')
  })

  it('explains partial coverage and disables answers during another action', () => {
    const lunch = question({ candidates: [{ ...candidate(901, 'the $20 you took out on Aug 3', 20), covers_cents: 2000 }] })
    render(<CashPurchaseQuestions questions={[lunch]} disabled onAnswer={vi.fn()} />)
    expect(screen.getByText(/the other \$20 still counts on its own/)).toBeTruthy()
    expect(screen.getAllByRole('button').every(button => (button as HTMLButtonElement).disabled)).toBe(true)
  })

  it('says when Review lists only the newest of the purchases Home counts', () => {
    const { rerender } = render(<CashPurchaseQuestions questions={[question()]} totalCount={23} onAnswer={vi.fn()} />)
    expect(screen.getByText('Showing the newest 1 of 23. The rest appear as you answer these.')).toBeTruthy()
    rerender(<CashPurchaseQuestions questions={[question()]} totalCount={1} onAnswer={vi.fn()} />)
    expect(screen.queryByText(/Showing the newest/)).toBeNull()
  })
})
