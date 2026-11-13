// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { ParticipantTabs } from './ParticipantTabs'
const brandState = vi.hoisted(() => ({ assistantName: 'Mia' }))
vi.mock('../contexts/brandContextValue', () => ({ useBrand: () => ({ assistantName: brandState.assistantName, brand: { short_name: 'Household CFO', participant_role_term: 'Participant' } }) }))
afterEach(() => { cleanup(); vi.unstubAllGlobals() })
it('keeps one Savings tab and only challenge destinations in More', () => {
  const change = vi.fn()
  render(<ParticipantTabs savingsChallenge sections={['Home', 'Review', 'Ask Mia', 'My Money', 'Budget', 'My Profile', 'Statements']} activeSection="Statements" onChange={change} />)
  const nav = screen.getByRole('navigation')
  expect(within(nav).queryByRole('button', { name: 'Today' })).toBeNull()
  expect(within(nav).getByRole('link', { name: 'Savings' })).toBeTruthy()
  expect(within(nav).getByRole('link', { name: 'Statements' }).getAttribute('aria-current')).toBe('page')
  fireEvent.click(screen.getByRole('button', { name: 'More' }))
  expect(screen.getByRole('link', { name: 'My Profile' })).toBeTruthy()
  for (const label of ['My Money', 'Transactions', 'Budget']) expect(screen.queryByRole('link', { name: label })).toBeNull()
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

it('uses coach order for tabs and More without regrouping tools', () => {
  render(<ParticipantTabs customModuleOrder sections={['Statements', 'Wealth', 'Home', 'Ask Mia', 'Optionality', 'Review', 'CFO Filter', 'Budget']} activeSection="Optionality" onChange={vi.fn()} />)
  expect(within(screen.getByRole('navigation')).getAllByRole('link').map(link => link.getAttribute('aria-label'))).toEqual(['Statements', 'Wealth', 'Home', 'Ask Mia'])
  fireEvent.click(screen.getByRole('button', { name: 'More' }))
  expect(within(screen.getByRole('dialog', { name: 'More' })).getAllByRole('link').map(link => link.getAttribute('aria-label'))).toEqual(['Optionality', 'Review', 'CFO Filter', 'Budget'])
})


it('lists all destinations on laptops without a More dialog', () => {
  vi.stubGlobal('matchMedia', () => ({ matches: true, addEventListener: vi.fn(), removeEventListener: vi.fn() }))
  render(<ParticipantTabs sections={['Home', 'Ask Mia', 'Budget', 'Review', 'My Money', 'Statements', 'Wealth']} activeSection="Wealth" onChange={vi.fn()} reviewCount={2} />)
  expect(screen.queryByRole('button', { name: 'More' })).toBeNull()
  expect(screen.getAllByRole('link').map(link => link.getAttribute('aria-label'))).toEqual(['Home', 'Ask Mia', 'Budget', 'Review', 'My Money', 'Statements', 'Wealth'])
  expect(screen.getByRole('link', { name: 'Wealth' }).getAttribute('aria-current')).toBe('page')
  expect(screen.getByLabelText('2 purchases waiting')).toBeTruthy()
})

it('releases the live More dialog and scroll ownership before opening Account', async () => {
  const account = vi.fn()
  render(<ParticipantTabs sections={['Home', 'My Profile']} activeSection="Home" onChange={vi.fn()} onAccount={account} />)
  fireEvent.click(screen.getByRole('button', { name: 'More' }))
  expect(document.body.style.overflow).toBe('hidden')
  fireEvent.click(screen.getByRole('button', { name: 'Account and help' }))
  expect(screen.queryByRole('dialog')).toBeNull()
  expect(document.body.style.overflow).toBe('')
  await waitFor(() => expect(account).toHaveBeenCalledTimes(1))
})


it('keeps Account reachable through More when a program has no secondary destinations', async () => {
  render(<ParticipantTabs sections={['Home', 'Ask Mia']} activeSection="Ask Mia" onChange={vi.fn()} onAccount={vi.fn()} />)
  fireEvent.click(screen.getByRole('button', { name: 'More' }))
  expect(screen.getByRole('dialog', { name: 'More' })).toBeTruthy()
  const account = screen.getByRole('button', { name: 'Account and help' })
  await waitFor(() => expect(document.activeElement).toBe(account))
})

it('keeps the Review badge when coach ordering places Review after the primary destinations', () => {
  vi.stubGlobal('matchMedia', () => ({ matches: true, addEventListener: vi.fn(), removeEventListener: vi.fn() }))
  render(<ParticipantTabs customModuleOrder sections={['Statements', 'Home', 'Budget', 'My Money', 'Review']} activeSection="Review" onChange={vi.fn()} reviewCount={3} />)
  expect(within(screen.getByRole('link', { name: 'Review' })).getByLabelText('3 purchases waiting')).toBeTruthy()
})


it('replaces an open phone sheet with the sidebar and releases its scroll lock', async () => {
  let desktop = false
  const listeners: Array<() => void> = []
  vi.stubGlobal('matchMedia', () => ({ get matches() { return desktop }, addEventListener: (_: string, listener: () => void) => listeners.push(listener), removeEventListener: vi.fn() }))
  const view = render(<ParticipantTabs sections={['Home', 'My Profile']} activeSection="Home" onChange={vi.fn()} />)
  fireEvent.click(screen.getByRole('button', { name: 'More' }))
  expect(document.body.style.overflow).toBe('hidden')
  act(() => { desktop = true; listeners.forEach(listener => listener()) })
  expect(screen.queryByRole('dialog')).toBeNull()
  expect(document.body.style.overflow).toBe('')
  await waitFor(() => expect(view.container.querySelector('.is-tools-open')).toBeNull())
  act(() => { desktop = false; listeners.forEach(listener => listener()) })
  expect(screen.getByRole('button', { name: 'More' }).getAttribute('aria-expanded')).toBe('false')
})
