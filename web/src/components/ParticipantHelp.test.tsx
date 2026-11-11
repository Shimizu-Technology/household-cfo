// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { CoachParticipant } from '../lib/coachChallengeApi'
import { useWorkspaceMutationInFlight } from './coachWorkspaceMutationLifecycle'

const challenge = vi.hoisted(() => ({ scopes: vi.fn(), help: vi.fn(), ticket: vi.fn(), ticketStatus: vi.fn() }))
vi.mock('../lib/coachChallengeApi', async original => ({ ...await original<typeof import('../lib/coachChallengeApi')>(), coachChallengeApi: challenge }))
import { ParticipantHelp } from './ParticipantHelp'

const request = (id: number, status = 'open') => ({ id, status })
const row = (over = {}) => ({ enrollment_id: 41, help_requests: [request(1), request(2)], more_help_requests: true, ...over }) as unknown as CoachParticipant
function Probe() { return <p data-testid="lock">{useWorkspaceMutationInFlight() ? 'locked' : 'free'}</p> }

beforeEach(() => {
  vi.resetAllMocks()
  challenge.scopes.mockResolvedValue({ enrollment_id: 41, summary_available: false, selected_records: [], support_access: [] })
})
afterEach(cleanup)

describe('Help requests', () => {
  it('adds each page of older requests to the ones already shown, without repeating any', async () => {
    challenge.help
      .mockResolvedValueOnce({ records: [request(2), request(3), request(4)], next_cursor: 4 })
      .mockResolvedValueOnce({ records: [request(5)], next_cursor: null })
    render(<ParticipantHelp row={row()} />)
    fireEvent.click(await screen.findByRole('button', { name: 'More help requests' }))
    expect(await screen.findByRole('button', { name: /Help request 4/ })).toBeTruthy()
    expect(screen.getAllByRole('button', { name: /^Help request / }).map(item => item.textContent?.slice(0, 14))).toEqual(['Help request 1', 'Help request 2', 'Help request 3', 'Help request 4'])
    fireEvent.click(screen.getByRole('button', { name: 'More help requests' }))
    expect(await screen.findByRole('button', { name: /Help request 5/ })).toBeTruthy()
    expect(screen.getAllByRole('button', { name: /^Help request / })).toHaveLength(5)
    expect(screen.queryByRole('button', { name: 'More help requests' })).toBeNull()
    expect(challenge.help).toHaveBeenNthCalledWith(2, 41, 4, expect.any(AbortSignal))
  })

  it('holds the program until a status change lands, even when this panel closes first, then tells the screen behind', async () => {
    let finish: (value: unknown) => void = () => {}
    challenge.ticket.mockResolvedValue({ id: 1, status: 'open', message: 'Please help' })
    challenge.ticketStatus.mockReturnValue(new Promise(resolve => { finish = resolve }))
    const changed = vi.fn()
    render(<Probe />)
    const { unmount } = render(<ParticipantHelp row={row({ more_help_requests: false })} onTicketChanged={changed} />)
    fireEvent.click(await screen.findByRole('button', { name: /Help request 1/ }))
    fireEvent.click(await screen.findByRole('button', { name: 'Mark resolved' }))
    await waitFor(() => expect(screen.getByTestId('lock').textContent).toBe('locked'))
    unmount()
    expect(challenge.ticketStatus).toHaveBeenCalledWith(41, 1, 'resolved', expect.any(AbortSignal))
    expect((challenge.ticketStatus.mock.calls[0][3] as AbortSignal).aborted).toBe(false)
    expect(screen.getByTestId('lock').textContent).toBe('locked')
    await act(async () => { finish({ id: 1, status: 'resolved' }) })
    expect(changed).toHaveBeenCalledTimes(1)
    expect(screen.getByTestId('lock').textContent).toBe('free')
  })

  it('shows the new status on the request that was changed', async () => {
    challenge.ticket.mockResolvedValue({ id: 1, status: 'open', message: 'Please help' })
    challenge.ticketStatus.mockResolvedValue({ id: 1, status: 'resolved' })
    render(<><Probe /><ParticipantHelp row={row({ more_help_requests: false })} /></>)
    fireEvent.click(await screen.findByRole('button', { name: /Help request 1/ }))
    fireEvent.click(await screen.findByRole('button', { name: 'Mark resolved' }))
    expect(await screen.findByRole('heading', { name: 'Help request 1 · Resolved' })).toBeTruthy()
    await waitFor(() => expect(screen.getByTestId('lock').textContent).toBe('free'))
  })
})
