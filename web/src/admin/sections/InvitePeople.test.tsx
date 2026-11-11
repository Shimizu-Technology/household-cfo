// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { group, staff } from '../../test/adminFixtures'
const api = vi.hoisted(() => ({ createAdminUser: vi.fn() }))
vi.mock('../../api', async original => ({ ...await original<typeof import('../../api')>(), ...api }))
vi.mock('../../lib/confirmAction', () => ({ confirmAction: async () => true }))
import { InvitePeople } from './InvitePeople'
import type { RosterGroup } from '../useAdminRoster'
beforeEach(() => vi.resetAllMocks())
afterEach(cleanup)
const groups = [group(2, 'Savings')] as unknown as RosterGroup[]
function open(onDone = vi.fn()) {
  render(<InvitePeople currentUser={staff()} groups={groups} people={[]} defaultGroupId={2} onClose={vi.fn()} onDone={onDone} />)
}
it.each(['ApiDeadlineError', 'TypeError'])('stops on %s, retains completed results and retries only unattempted addresses', async name => {
  const failure = new Error('Connection interrupted'); failure.name = name
  api.createAdminUser.mockResolvedValueOnce({ invitation_sent: true }).mockRejectedValueOnce(failure)
  open()
  fireEvent.change(screen.getByLabelText(/Email addresses/), { target: { value: 'one@example.com two@example.com three@example.com' } })
  fireEvent.click(screen.getByRole('button', { name: 'Invite 3 people' }))
  expect(await screen.findByText('1 person invited.')).toBeTruthy()
  expect(screen.getByText('Not sent yet: three@example.com.')).toBeTruthy()
  expect(api.createAdminUser).toHaveBeenCalledTimes(2)
  fireEvent.click(screen.getByRole('button', { name: 'Retry remaining addresses' }))
  expect((screen.getByLabelText(/Email addresses/) as HTMLTextAreaElement).value).toBe('three@example.com')
})
it.each([{ already_invited: true }, { created: false, reactivated: false }])('refreshes an existing invitation added to another group: %j', async response => {
  api.createAdminUser.mockResolvedValue({ ...response, invitation_sent: false })
  const done = vi.fn(); open(done)
  fireEvent.change(screen.getByLabelText(/Email addresses/), { target: { value: 'existing@example.com' } })
  fireEvent.click(screen.getByRole('button', { name: 'Invite' }))
  expect(await screen.findByText('Already invited; added to Savings: existing@example.com.')).toBeTruthy()
  await waitFor(() => expect(done).toHaveBeenCalledTimes(1))
})
it('hides the backdrop from assistive technology and prevents closing while saving', async () => {
  let finish!: (value: unknown) => void
  api.createAdminUser.mockReturnValue(new Promise(resolve => { finish = resolve }))
  open()
  const backdrop = document.querySelector('.pilot-dialog-backdrop')!
  expect(backdrop.tagName).toBe('DIV')
  expect(backdrop.getAttribute('aria-hidden')).toBe('true')
  fireEvent.change(screen.getByLabelText(/Email addresses/), { target: { value: 'one@example.com' } })
  fireEvent.click(screen.getByRole('button', { name: 'Invite' }))
  await waitFor(() => expect((screen.getByRole('button', { name: 'Close' }) as HTMLButtonElement).disabled).toBe(true))
  fireEvent.click(backdrop)
  expect(screen.getByRole('dialog')).toBeTruthy()
  finish({ invitation_sent: true })
  await screen.findByText('1 person invited.')
})
