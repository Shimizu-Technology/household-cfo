// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { createRef } from 'react'
import { afterEach, expect, it, vi } from 'vitest'
import { ChatHistory } from './ChatHistory'

vi.mock('../contexts/brandContextValue', () => ({ useBrand: () => ({ assistantName: 'Mia' }) }))
afterEach(() => { cleanup(); vi.resetAllMocks() })

const baseProps = {
  messages: [],
  totalMessageCount: 0,
  hiddenMessageCount: 0,
  olderMessageCount: 0,
  historyLoading: false,
  miaLoading: false,
  showScrollButton: false,
  chatCardRef: createRef<HTMLElement>(),
  onScroll: () => undefined,
  onLoadEarlier: () => undefined,
  onScrollLatest: () => undefined,
  imports: [],
  onOpenLocal: () => undefined,
  onOpenImport: () => undefined,
  onOpenImportId: () => undefined,
  onReviewImportId: () => undefined,
}

it('greets with starting points that fill the composer instead of sending', () => {
  const choose = vi.fn()
  render(<ChatHistory {...baseProps} starterPrompts={[{ label: 'Update a debt', message: 'Help me update one of my household debts.' }]} onChoosePrompt={choose} />)
  expect(screen.getByRole('heading', { name: 'Hi, I’m Mia.' })).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: 'Update a debt' }))
  expect(choose).toHaveBeenCalledWith('Help me update one of my household debts.')
})

it('opens the server-specified missing money input from Mia’s answer', () => {
  const open = vi.fn()
  render(<ChatHistory {...baseProps} totalMessageCount={1} onOpenMoneyInput={open} messages={[{role:'assistant', author:'Mia', content:'Still to add: debt minimums.', setup_help:{available:false,money_inputs:['debt','accounts']}}]} />)
  fireEvent.click(screen.getByRole('button',{name:'Add debt minimums'}))
  expect(open).toHaveBeenCalledWith('debt')
  fireEvent.click(screen.getByRole('button',{name:'Add account balances'}))
  expect(open).toHaveBeenLastCalledWith('accounts')
})

it('omits starting points when none are offered', () => {
  render(<ChatHistory {...baseProps} />)
  expect(screen.queryByRole('group', { name: 'Ways to start' })).toBeNull()
})

const twoMessages = [
  { role: 'user' as const, author: 'You', content: 'spent 40 at shell' },
  { role: 'assistant' as const, author: 'Mia', content: 'Here is what I found.' },
]

it('keeps pending review cards after the conversation in one group', () => {
  render(<ChatHistory {...baseProps} messages={twoMessages} totalMessageCount={2} reviewCount={3} reviewContent={<p>Transactions to review</p>} />)
  const queue = document.querySelector('.chat-review-queue')
  expect(queue?.textContent).toBe('Transactions to review')
  const rows = document.querySelectorAll('.chat-card > *')
  expect(rows[rows.length - 2]).toBe(queue)
  expect(rows[rows.length - 1].className).toBe('chat-turn-spacer')
  expect(queue?.previousElementSibling?.classList.contains('message-row')).toBe(true)
})

it('uses the same review wording and destination in a thread and keeps Latest independent', () => {
  const onOpenReview = vi.fn()
  const onScrollLatest = vi.fn()
  render(<ChatHistory {...baseProps} messages={twoMessages} totalMessageCount={2} showScrollButton reviewCount={3} onOpenReview={onOpenReview} onScrollLatest={onScrollLatest} reviewContent={<p>Transactions to review</p>} />)
  const link = screen.getByRole('button', { name: '3 changes to review' })
  fireEvent.click(link)
  expect(onOpenReview).toHaveBeenCalledOnce()
  expect(link.closest('.chat-card')).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: 'Scroll to latest Mia message' }))
  expect(onScrollLatest).toHaveBeenCalledOnce()
})

it('keeps the plain latest-message shortcut when nothing waits for review', () => {
  render(<ChatHistory {...baseProps} messages={twoMessages} totalMessageCount={2} showScrollButton />)
  expect(screen.getByRole('button', { name: 'Scroll to latest Mia message' })).toBeTruthy()
  expect(document.querySelector('.chat-review-queue')).toBeNull()
})

it('shows one review line before the first message instead of the review cards', () => {
  const onOpenReview = vi.fn()
  render(<ChatHistory {...baseProps} reviewCount={2} pendingPurchaseCount={2} onOpenReview={onOpenReview} reviewContent={<p>Large old review card</p>} />)
  const link = screen.getByRole('button', { name: '2 purchases to review' })
  expect(document.querySelector('.chat-card')?.firstElementChild).toBe(link)
  expect(screen.queryByText('Large old review card')).toBeNull()
  fireEvent.click(link)
  expect(onOpenReview).toHaveBeenCalledOnce()
})

it('fades only a newly received assistant reply, leaving history and the sent message still', () => {
  const { rerender } = render(<ChatHistory {...baseProps} messages={twoMessages} totalMessageCount={2} />)
  const sent = { id: 3, role: 'user' as const, author: 'You', content: 'What changed?' }
  rerender(<ChatHistory {...baseProps} messages={[...twoMessages, sent]} totalMessageCount={3} miaLoading />)
  expect(document.querySelectorAll('.is-new-reply')).toHaveLength(0)
  rerender(<ChatHistory {...baseProps} messages={[...twoMessages, sent, { id: 4, role: 'assistant', author: 'Mia', content: 'Your reply.' }]} totalMessageCount={4} freshReplyId={4} />)
  expect(document.querySelectorAll('.is-new-reply')).toHaveLength(1)
  expect(document.querySelector('.is-new-reply')?.textContent).toContain('Your reply.')
})

it('keeps challenge check-ins and recovery visible when the household review cards collapse', () => {
  render(<ChatHistory {...baseProps} reviewCount={2} onOpenReview={vi.fn()} emptyReviewContent={<p role="alert">Retry loading your saved check-in</p>} reviewContent={<p>Household review card</p>} />)
  expect(screen.getByRole('alert').textContent).toBe('Retry loading your saved check-in')
  expect(screen.queryByText('Household review card')).toBeNull()
})

it('labels comparison values in participant words without Scenario only', () => {
  render(<ChatHistory {...baseProps} totalMessageCount={1} messages={[{
    role: 'assistant', author: 'Mia', content: 'Compare these possibilities.', presentation: {
      version: 1, kind: 'read_only_answer', basis: 'scenario_only', lead: 'Here is the comparison.',
      sections: [{ id: 'purchase', title: 'Purchase', body: 'Your plan would change.' }],
      scenario: { values: [{ label: 'Stroller', display_value: '$300' }] },
    },
  }]} />)
  expect(screen.getByRole('note', { name: 'For comparison · nothing saved' })).toBeTruthy()
  expect(screen.queryByText('Scenario only · not saved')).toBeNull()
})
