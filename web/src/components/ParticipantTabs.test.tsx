// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { ParticipantTabs } from './ParticipantTabs'
vi.mock('../contexts/brandContextValue', () => ({ useBrand: () => ({ assistantName: 'Mia', brand: { short_name: 'VERA', participant_role_term: 'Participant' } }) }))
afterEach(cleanup)
it('keeps the challenge’s core tasks visible and finance tools secondary', () => {
  const change = vi.fn(); const today = vi.fn()
  render(<ParticipantTabs savingsChallenge sections={['Home', 'Review', 'Ask Mia', 'Budget', 'My Profile', 'Statements']} activeSection="Statements" onChange={change} onToday={today} />)
  const nav = screen.getByRole('navigation')
  fireEvent.click(within(nav).getByRole('button', { name: 'Today' })); expect(today).toHaveBeenCalledOnce()
  expect(within(nav).getByRole('link', { name: 'Savings' })).toBeTruthy()
  expect(within(nav).getByRole('link', { name: 'Statements' }).getAttribute('aria-current')).toBe('page')
  expect(within(nav).queryByRole('link', { name: 'Budget' })).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: 'Tools' }))
  const transactions = screen.getByRole('link', { name: 'Transactions' })
  expect(transactions.textContent).toContain('Transactions')
  expect(transactions.getAttribute('href')).toBe('#Review')
  expect(screen.queryByRole('link', { name: 'Review' })).toBeNull()
  fireEvent.click(transactions)
  expect(change).toHaveBeenCalledWith('Review')
})
it('preserves the ordinary CFO primary destinations', () => {
  render(<ParticipantTabs sections={['Home', 'Review', 'Ask Mia', 'Budget', 'Statements']} activeSection="Budget" onChange={vi.fn()} />)
  expect(screen.getByRole('link', { name: 'Budget' }).getAttribute('aria-current')).toBe('page')
  expect(screen.queryByRole('link', { name: 'Savings' })).toBeNull()
  expect(screen.getByRole('link', { name: 'Review' }).textContent).toContain('Review')
  expect(screen.queryByRole('link', { name: 'Transactions' })).toBeNull()
})
