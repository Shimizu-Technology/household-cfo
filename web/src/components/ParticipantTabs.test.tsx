// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { ParticipantTabs } from './ParticipantTabs'
import { useState } from 'react'
import { usePilotDialog } from '../lib/usePilotDialog'
const brandState = vi.hoisted(() => ({ assistantName: 'Mia' }))
vi.mock('../contexts/brandContextValue', () => ({ useBrand: () => ({ assistantName: brandState.assistantName, brand: { short_name: 'Household CFO', participant_role_term: 'Participant' } }) }))
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
  fireEvent.click(screen.getByRole('button', { name: 'More' }))
  expect(screen.getByRole('link', { name: 'My Money' }).getAttribute('href')).toBe('#My%20Money')
  const transactions = screen.getByRole('link', { name: 'Transactions' })
  expect(transactions.textContent).toContain('Transactions')
  expect(transactions.getAttribute('href')).toBe('#Review')
  expect(screen.queryByRole('link', { name: 'Review' })).toBeNull()
  fireEvent.click(transactions)
  expect(change).toHaveBeenCalledWith('Review')
})
it('keeps Home, Mia, Budget, and Review under the thumb and money details in More', () => {
  render(<ParticipantTabs sections={['Home', 'Review', 'Ask Mia', 'My Money', 'Budget', 'Statements']} activeSection="Budget" onChange={vi.fn()} />)
  const nav = screen.getByRole('navigation')
  expect(within(nav).getAllByRole('link').map(link => link.getAttribute('aria-label'))).toEqual(['Home', 'Ask Mia', 'Budget', 'Review'])
  expect(within(nav).getByRole('link', { name: 'Budget' }).getAttribute('aria-current')).toBe('page')
  expect(within(nav).queryByRole('link', { name: 'My Money' })).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: 'More' }))
  expect(screen.getByRole('dialog', { name: 'More' })).toBeTruthy()
  expect(screen.getByRole('link', { name: 'My Money' }).getAttribute('href')).toBe('#My%20Money')
  expect(screen.getByRole('link', { name: 'Statements' }).getAttribute('href')).toBe('#Statements')
  expect(screen.queryByRole('link', { name: 'Savings' })).toBeNull()
  expect(screen.queryByRole('link', { name: 'Transactions' })).toBeNull()
})

it('promotes My Money when a program does not include Budget', () => {
  render(<ParticipantTabs sections={['Home', 'Review', 'Ask Mia', 'My Money', 'Wealth']} activeSection="Home" onChange={vi.fn()} />)
  const nav = screen.getByRole('navigation')
  expect(within(nav).getAllByRole('link').map(link => link.getAttribute('aria-label'))).toEqual(['Home', 'Ask Mia', 'Review', 'My Money'])
  expect(within(nav).getByRole('button', { name: 'More' })).toBeTruthy()
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
it('uses a short Mia label in the tab bar and keeps visible and accessible names aligned', () => {
  brandState.assistantName = 'Mia for Mrs. Mel BOG (QA)'
  try {
    render(<ParticipantTabs savingsChallenge sections={['Home', 'Ask Mia', 'Statements']} activeSection="Home" onChange={vi.fn()} />)
    const nav = screen.getByRole('navigation')
    expect(within(nav).getByRole('link', { name: 'Ask Mia for Mrs. Mel BOG (QA)' }).querySelector('.tabs-label-short')?.textContent).toBe('Mia')
    const statements = within(nav).getByRole('link', { name: 'Statements' })
    expect(statements.querySelector('.tabs-label-short')?.textContent).toBe('Statements')
  } finally {
    brandState.assistantName = 'Mia'
  }
})

it('groups enabled framework tools under one Tools entry and preserves route links', () => {
  const change = vi.fn()
  render(<ParticipantTabs sections={['Home', 'Budget', 'Wealth', 'Optionality']} activeSection="Home" onChange={change} />)
  fireEvent.click(screen.getByRole('button', { name: 'More' }))
  expect(document.querySelector('.tabs-tools-group')?.hasAttribute('open')).toBe(false)
  const summary = screen.getByText('Tools')
  fireEvent.click(summary)
  // jsdom does not implement the native details toggle on click.
  summary.parentElement?.setAttribute('open', '')
  fireEvent.click(screen.getByRole('link', { name: 'Wealth' }))
  expect(change).toHaveBeenCalledWith('Wealth')
  expect(screen.queryByRole('dialog')).toBeNull()
})
it('identifies the active More destination and opens its tool group', () => {
  render(<ParticipantTabs sections={['Home', 'Wealth']} activeSection="Wealth" onChange={vi.fn()} />)
  expect(screen.getByRole('button', { name: 'More' }).getAttribute('aria-description')).toBe('Current section: Wealth')
  fireEvent.click(screen.getByRole('button', { name: 'More' }))
  expect(screen.getByRole('link', { name: 'Wealth' }).getAttribute('aria-current')).toBe('page')
})
it('shows only staff destinations for a staff-only shell and preserves modified links', () => {
  const change = vi.fn()
  render(<ParticipantTabs staffOnly sections={['Home', 'Budget', 'Coach Studio', 'Admin']} activeSection="Coach Studio" onChange={change} />)
  expect(screen.getByRole('navigation', { name: 'Staff sections' })).toBeTruthy()
  expect(screen.queryByRole('link', { name: 'Home' })).toBeNull()
  expect(screen.queryByRole('button', { name: 'More' })).toBeNull()
  const studio = screen.getByRole('link', { name: 'Coach Studio' })
  expect(studio.getAttribute('aria-current')).toBe('page')
  expect(studio.getAttribute('href')).toBe('#Coach%20Studio')
  fireEvent.click(studio, { ctrlKey: true })
  expect(change).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('link', { name: 'Admin' }))
  expect(change).toHaveBeenCalledWith('Admin')
})

it('returns to More when the parent keeps the current route after a guarded selection', async () => {
  render(<ParticipantTabs sections={['Home', 'Ask Mia', 'Budget', 'Review', 'My Money']} activeSection="Home" onChange={vi.fn()} />)
  const more = screen.getByRole('button', { name: 'More' })
  fireEvent.click(more)
  const destination = screen.getByRole('link', { name: 'My Money' })
  destination.focus()
  fireEvent.click(destination)
  await waitFor(() => expect(document.activeElement).toBe(more))
  expect(screen.queryByRole('dialog')).toBeNull()
})
