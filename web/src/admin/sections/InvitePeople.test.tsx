// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useWorkspaceMutationInFlight } from '../../components/coachWorkspaceMutationLifecycle'
import { registerConfirmHost } from '../../lib/confirmAction'
import { person, staff } from '../../test/adminFixtures'

const api = vi.hoisted(() => ({ createAdminUser: vi.fn() }))
vi.mock('../../api', async original => ({ ...await original<typeof import('../../api')>(), ...api }))
import { InvitePeople } from './InvitePeople'

const groups = [{ id: 2, name: 'Bank of Guam 90 day savings', status: 'enrolling' as const, savingsChallenge: true, detail: null }]
let unregister = () => {}
function Probe() { return <p data-testid="lock">{useWorkspaceMutationInFlight() ? 'locked' : 'free'}</p> }
const setup = (onClose = vi.fn(), onDone = vi.fn()) => render(<><Probe /><InvitePeople currentUser={staff()} groups={groups} people={[person(1, 'Ana Lopez')]} defaultGroupId={2} onClose={onClose} onDone={onDone} /></>)

beforeEach(() => {
  vi.resetAllMocks()
  unregister = registerConfirmHost(request => request.resolve(true))
})
afterEach(() => { cleanup(); unregister() })

describe('Invite people', () => {
  it('keeps the entries it could not use in the result instead of dropping them', async () => {
    api.createAdminUser.mockResolvedValue({ user: {}, invitation_sent: true, invitation_status: 'sent' })
    setup()
    fireEvent.change(screen.getByLabelText(/Email addresses/), { target: { value: 'bo@x.test, not-an-email' } })
    fireEvent.click(screen.getByRole('button', { name: 'Invite' }))
    expect(await screen.findByText('1 person invited.')).toBeTruthy()
    expect(screen.getByText('Not everything you typed was used:')).toBeTruthy()
    expect(screen.getByText('“not-an-email” isn’t a complete email address.')).toBeTruthy()
  })

  it('cannot be closed while the batch runs, holds the program until the last answer, and then shows every result', async () => {
    const pending: Array<(value: unknown) => void> = []
    api.createAdminUser.mockImplementation(() => new Promise(resolve => { pending.push(resolve) }))
    const onClose = vi.fn()
    setup(onClose)
    fireEvent.change(screen.getByLabelText(/Email addresses/), { target: { value: 'a@x.test, b@x.test' } })
    fireEvent.click(screen.getByRole('button', { name: 'Invite 2 people' }))
    await waitFor(() => expect(pending).toHaveLength(1))
    expect(screen.getByTestId('lock').textContent).toBe('locked')
    const dialog = screen.getByRole('dialog')
    expect(within(dialog).getByRole('button', { name: 'Close' })).toHaveProperty('disabled', true)
    fireEvent.keyDown(document, { key: 'Escape' })
    fireEvent.click(screen.getByRole('button', { name: 'Close invite people' }))
    expect(onClose).not.toHaveBeenCalled()
    await act(async () => { pending[0]({ user: {}, invitation_sent: true, invitation_status: 'sent' }) })
    await waitFor(() => expect(pending).toHaveLength(2))
    await act(async () => { pending[1]({ user: {}, invitation_sent: true, invitation_status: 'sent' }) })
    expect(await screen.findByText('2 people invited.')).toBeTruthy()
    expect(screen.getByTestId('lock').textContent).toBe('free')
    fireEvent.click(screen.getByRole('button', { name: 'Close' }))
    expect(onClose).toHaveBeenCalled()
  })
})
