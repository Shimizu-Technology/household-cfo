// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { ParticipantTabs } from './ParticipantTabs'
import { useState } from 'react'
import { usePilotDialog } from '../lib/usePilotDialog'
vi.mock('../contexts/brandContextValue', () => ({ useBrand: () => ({ assistantName: 'Mia', brand: { short_name: 'VERA', participant_role_term: 'Participant' } }) }))
afterEach(cleanup)
it('keeps the challenge’s core tasks visible and finance tools secondary', () => {
  const change = vi.fn(); const today = vi.fn()
  render(<ParticipantTabs savingsChallenge sections={['Home', 'Review', 'Ask Mia', 'My Money', 'Budget', 'My Profile', 'Statements']} activeSection="Statements" onChange={change} onToday={today} />)
  const nav = screen.getByRole('navigation')
  fireEvent.click(within(nav).getByRole('button', { name: 'Today' })); expect(today).toHaveBeenCalledOnce()
  expect(within(nav).getByRole('link', { name: 'Savings' })).toBeTruthy()
  expect(within(nav).getByRole('link', { name: 'Statements' }).getAttribute('aria-current')).toBe('page')
  expect(within(nav).queryByRole('link', { name: 'Budget' })).toBeNull()
  expect(within(nav).queryByRole('link', { name: 'My Money' })).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: 'Tools' }))
  expect(screen.getByRole('link', { name: 'My Money' }).getAttribute('href')).toBe('#My%20Money')
  const transactions = screen.getByRole('link', { name: 'Transactions' })
  expect(transactions.textContent).toContain('Transactions')
  expect(transactions.getAttribute('href')).toBe('#Review')
  expect(screen.queryByRole('link', { name: 'Review' })).toBeNull()
  fireEvent.click(transactions)
  expect(change).toHaveBeenCalledWith('Review')
})
it('makes money details primary while preserving the annual plan in Tools', () => {
  render(<ParticipantTabs sections={['Home', 'Review', 'Ask Mia', 'My Money', 'Budget', 'Statements']} activeSection="My Money" onChange={vi.fn()} />)
  expect(screen.getByRole('link', { name: 'My Money' }).getAttribute('aria-current')).toBe('page')
  expect(screen.queryByRole('link', { name: 'Budget' })).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: 'Tools' }))
  expect(screen.getByRole('link', { name: 'Budget' }).getAttribute('href')).toBe('#Budget')
  expect(screen.queryByRole('link', { name: 'Savings' })).toBeNull()
  expect(screen.getByRole('link', { name: 'Review' }).textContent).toContain('Review')
  expect(screen.queryByRole('link', { name: 'Transactions' })).toBeNull()
})

it('restores Today focus after a pointer activation that does not focus buttons natively', async () => {
  function Journal({ close }: { close: () => void }) {
    const dialog = usePilotDialog(close)
    return <section ref={dialog} role="dialog"><button onClick={close}>Close Today</button></section>
  }
  function Page() {
    const [opened, setOpened] = useState(false)
    return <><input aria-label="Previous field" /><ParticipantTabs savingsChallenge sections={['Home']} activeSection="Home" onChange={vi.fn()} onToday={() => setOpened(true)} />{opened && <Journal close={() => setOpened(false)} />}</>
  }
  render(<Page />)
  screen.getByRole('textbox', { name: 'Previous field' }).focus()
  const today = screen.getByRole('button', { name: 'Today' })
  // fireEvent.click leaves focus unchanged, as pointer clicks can do in Safari.
  fireEvent.click(today)
  const close = await screen.findByRole('button', { name: 'Close Today' })
  await new Promise<void>(resolve => requestAnimationFrame(() => resolve()))
  expect(document.activeElement).toBe(close)
  fireEvent.keyDown(document, { key: 'Escape' })
  expect(screen.queryByRole('dialog')).toBeNull()
  expect(document.activeElement).toBe(today)
})
