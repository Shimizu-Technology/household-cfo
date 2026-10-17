// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { createRef } from 'react'
import { afterEach, expect, it, vi } from 'vitest'
import { ChatHistory } from './ChatHistory'

vi.mock('../contexts/brandContextValue', () => ({ useBrand: () => ({ assistantName: 'Mia' }) }))
afterEach(cleanup)

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
  expect(rows[rows.length - 1]).toBe(queue)
})

it('offers a jump to waiting reviews instead of hiding them behind the reply', async () => {
  const scrollIntoView = vi.fn()
  Element.prototype.scrollIntoView = scrollIntoView
  render(<ChatHistory {...baseProps} messages={twoMessages} totalMessageCount={2} showScrollButton reviewCount={3} reviewContent={<p>Transactions to review</p>} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Jump to 3 items waiting for your review' }))
  expect(scrollIntoView).toHaveBeenCalled()
  expect(screen.queryByRole('button', { name: 'Scroll to latest Mia message' })).toBeNull()
})

it('keeps the plain latest-message shortcut when nothing waits for review', () => {
  render(<ChatHistory {...baseProps} messages={twoMessages} totalMessageCount={2} showScrollButton />)
  expect(screen.getByRole('button', { name: 'Scroll to latest Mia message' })).toBeTruthy()
  expect(document.querySelector('.chat-review-queue')).toBeNull()
})

it('shows the review shortcut only while the review queue is below the fold', async () => {
  let queueTop = 900
  const spy = vi.spyOn(Element.prototype, 'getBoundingClientRect').mockImplementation(function (this: Element) {
    const top = this.classList.contains('chat-review-queue') ? queueTop : 0
    const bottom = this.classList.contains('chat-card') ? 500 : top + 100
    return { top, bottom, left: 0, right: 300, width: 300, height: bottom - top, x: 0, y: top, toJSON: () => ({}) }
  })
  try {
    render(<ChatHistory {...baseProps} messages={twoMessages} totalMessageCount={2} showScrollButton reviewCount={2} reviewContent={<p>Transactions to review</p>} />)
    expect(await screen.findByRole('button', { name: 'Jump to 2 items waiting for your review' })).toBeTruthy()
    expect(document.querySelector('.chat-card-wrap')?.classList.contains('has-review-shortcut')).toBe(true)

    queueTop = 300
    fireEvent.scroll(document.querySelector('.chat-card')!)
    await waitFor(() => expect(screen.queryByRole('button', { name: /waiting for your review/ })).toBeNull())
    expect(document.querySelector('.chat-card-wrap')?.classList.contains('has-review-shortcut')).toBe(false)
  } finally {
    spy.mockRestore()
  }
})
