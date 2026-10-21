// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ParticipantPrivacyAccess } from './ParticipantPrivacyAccess'
import { privacyApi } from '../lib/privacyApi'
vi.mock('../lib/privacyApi', () => ({ privacyApi: { controls: vi.fn() } }))
vi.mock('./ChallengePrivacyDialog', () => ({
  ChallengePrivacyDialog: ({ actorScope }: { actorScope: { user_id: number; household_id: number } }) => (
    <section role="dialog">
      Private controls for {actorScope.user_id}:{actorScope.household_id}
    </section>
  ),
}))
afterEach(cleanup)
beforeEach(() => {
  vi.resetAllMocks()
  vi.mocked(privacyApi.controls).mockResolvedValue({
    actor_scope: { user_id: 7, household_id: 11 },
    records: [],
    next_cursor: null,
  })
})
describe('independent private control entry', () => {
  it('opens from self-only metadata without an active financial workspace', async () => {
    render(<ParticipantPrivacyAccess userId={7} participant savingsChallenge />)
    expect(privacyApi.controls).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Privacy & reminders' }))
    expect(await screen.findByRole('dialog')).toHaveProperty('textContent', 'Private controls for 7:11')
    expect(privacyApi.controls).toHaveBeenCalledWith(null, expect.any(AbortSignal))
  })
  it('rejects a foreign participant metadata response', async () => {
    vi.mocked(privacyApi.controls).mockResolvedValue({
      actor_scope: { user_id: 8, household_id: 11 },
      records: [],
      next_cursor: null,
    })
    render(<ParticipantPrivacyAccess userId={7} participant savingsChallenge />)
    fireEvent.click(screen.getByRole('button'))
    await screen.findByRole('alert')
    expect(screen.queryByRole('dialog')).toBeNull()
  })
  it('rejects a changed household instead of opening stale controls', async () => {
    render(<ParticipantPrivacyAccess userId={7} participant savingsChallenge householdId={12} />)
    fireEvent.click(screen.getByRole('button'))
    await screen.findByRole('alert')
    expect(screen.queryByRole('dialog')).toBeNull()
  })
  it('destroys the request on account switch and ignores the late response', async () => {
    let resolve!: (value: Awaited<ReturnType<typeof privacyApi.controls>>) => void
    vi.mocked(privacyApi.controls).mockImplementation(
      () =>
        new Promise((done) => {
          resolve = done
        })
    )
    const view = render(<ParticipantPrivacyAccess userId={7} participant savingsChallenge />)
    fireEvent.click(screen.getByRole('button'))
    view.rerender(<ParticipantPrivacyAccess userId={8} participant savingsChallenge />)
    resolve({ actor_scope: { user_id: 7, household_id: 11 }, records: [], next_cursor: null })
    await waitFor(() => expect(screen.getByRole('button').hasAttribute('disabled')).toBe(false))
    expect(screen.queryByRole('dialog')).toBeNull()
  })
  it('does not expose participant controls to staff or a signed-out identity', () => {
    const view = render(<ParticipantPrivacyAccess userId={7} participant={false} />)
    expect(screen.queryByRole('button')).toBeNull()
    view.rerender(<ParticipantPrivacyAccess userId={null} participant savingsChallenge />)
    expect(screen.queryByRole('button')).toBeNull()
    expect(privacyApi.controls).not.toHaveBeenCalled()
  })
})

it('opens household privacy without requesting savings enrollments and restores focus', async () => {
  render(<ParticipantPrivacyAccess userId={7} participant savingsChallenge={false} householdId={11} />)
  const trigger = screen.getByRole('button', { name: 'Privacy' })
  fireEvent.click(trigger)
  const dialog = await screen.findByRole('dialog', { name: 'Your household privacy' })
  expect(dialog.textContent).toContain('Sharing requires your permission')
  expect(dialog.textContent).not.toMatch(/savings|challenge|enrollment/i)
  expect(privacyApi.controls).not.toHaveBeenCalled()
  fireEvent.keyDown(document, { key: 'Escape' })
  expect(screen.queryByRole('dialog')).toBeNull()
  expect(document.activeElement).toBe(trigger)
})
it('keeps metadata-only recovery without guessing the current program', async () => {
  render(<ParticipantPrivacyAccess userId={7} participant />)
  fireEvent.click(screen.getByRole('button'))
  expect(await screen.findByRole('dialog')).toHaveProperty('textContent', 'Private controls for 7:11')
})
it('destroys household privacy when the program context changes', () => {
  const view = render(<ParticipantPrivacyAccess userId={7} participant savingsChallenge={false} />)
  fireEvent.click(screen.getByRole('button'))
  view.rerender(<ParticipantPrivacyAccess userId={7} participant savingsChallenge />)
  expect(screen.queryByRole('dialog')).toBeNull()
})

it('returns to the account summary when its menu closed behind the dialog', async () => {
  render(<details open><summary>Account and help</summary><ParticipantPrivacyAccess userId={7} participant savingsChallenge={false} /></details>)
  fireEvent.click(screen.getByRole('button', { name: 'Privacy' }))
  document.querySelector('details')!.open = false
  fireEvent.keyDown(document, { key: 'Escape' })
  await waitFor(() => expect(document.activeElement).toBe(screen.getByText('Account and help')))
})
