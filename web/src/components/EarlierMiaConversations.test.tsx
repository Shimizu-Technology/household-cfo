// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { fetchEarlierMiaMessages, type EarlierMiaMessages } from '../api'
import { EarlierMiaConversations } from './EarlierMiaConversations'
vi.mock('../api', () => ({ fetchEarlierMiaMessages: vi.fn() }))
afterEach(() => { cleanup(); vi.resetAllMocks() })
function page(id: number, hasOlder = false): EarlierMiaMessages {
  return { picture: 'history', read_only: true, messages: [{ id, role: 'assistant', author: 'Mia', content: `Earlier message ${id}`, financial_restart: { available: true, state: 'review_available' } }], oldest_message_id: id, older_message_count: hasOlder ? 1 : 0, has_older_messages: hasOlder }
}
it('shows earlier messages separately without old action buttons and prepends older pages', async () => {
  vi.mocked(fetchEarlierMiaMessages).mockResolvedValueOnce(page(10, true)).mockResolvedValueOnce(page(2))
  render(<EarlierMiaConversations onClose={vi.fn()} />)
  await screen.findByText('Earlier message 10')
  expect(screen.queryByRole('button', { name: /review start over|apply|reset/i })).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: /Load earlier messages/ }))
  await screen.findByText('Earlier message 2')
  expect(vi.mocked(fetchEarlierMiaMessages).mock.calls[1][0]).toBe(10)
  const messages = screen.getAllByText(/Earlier message \d+/)
  expect(messages.map(message => message.textContent)).toEqual(['Earlier message 2', 'Earlier message 10'])
})
it('offers retry after a failed read while retaining the same private-history scope', async () => {
  vi.mocked(fetchEarlierMiaMessages).mockRejectedValueOnce(new Error('History temporarily unavailable')).mockResolvedValueOnce(page(10))
  render(<EarlierMiaConversations onClose={vi.fn()} />)
  await screen.findByRole('alert')
  fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
  await screen.findByText('Earlier message 10')
  expect(screen.queryByRole('alert')).toBeNull()
})
it('aborts an outstanding history read on close and ignores its late response', async () => {
  let finish!: (value: EarlierMiaMessages) => void
  vi.mocked(fetchEarlierMiaMessages).mockImplementation(() => new Promise(resolve => { finish = resolve }))
  const view = render(<EarlierMiaConversations onClose={vi.fn()} />)
  await waitFor(() => expect(fetchEarlierMiaMessages).toHaveBeenCalledOnce())
  const signal = vi.mocked(fetchEarlierMiaMessages).mock.calls[0][1]!
  view.unmount()
  expect(signal.aborted).toBe(true)
  finish(page(10))
  expect(screen.queryByText('Earlier message 10')).toBeNull()
})
it('can retry the same older page from Load earlier after that page fails', async () => {
  vi.mocked(fetchEarlierMiaMessages).mockResolvedValueOnce(page(10, true)).mockRejectedValueOnce(new Error('Older page unavailable')).mockResolvedValueOnce(page(2))
  render(<EarlierMiaConversations onClose={vi.fn()} />)
  await screen.findByText('Earlier message 10')
  fireEvent.click(screen.getByRole('button', { name: /Load earlier messages/ }))
  await screen.findByRole('alert')
  fireEvent.click(screen.getByRole('button', { name: /Load earlier messages/ }))
  await screen.findByText('Earlier message 2')
  expect(screen.queryByRole('alert')).toBeNull()
  expect(vi.mocked(fetchEarlierMiaMessages).mock.calls.slice(1).map(call => call[0])).toEqual([10, 10])
})
