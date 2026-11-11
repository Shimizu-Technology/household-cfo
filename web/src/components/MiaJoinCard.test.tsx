// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { ApiRequestError, enrollSavingsChallenge, fetchSavingsChallenge } from '../api'
import type { SavingsChallenge, SavingsOffer } from '../lib/savingsChallenge'
import { MiaJoinCard } from './MiaJoinCard'
vi.mock('../api', async original => ({ ...await original<typeof import('../api')>(), fetchSavingsChallenge: vi.fn(), enrollSavingsChallenge: vi.fn() }))
const offer = (over: Partial<SavingsOffer> = {}): SavingsOffer => ({ cohort_release_id: 3, acceptance_digest: 'digest-1', policy_version: '1', time_zone: 'Pacific/Guam', cohort_label: 'Bank of Guam 90-Day Challenge', local_today: '2026-11-12', configured_starts_on: '2026-11-12', personal_starts_on: '2026-11-12', personal_ends_on: '2027-02-09', late_start_acceptance_required: false, accepting_enrollments: true, configured_ends_on: '2027-02-09', personal_ends_on_: undefined, ...over } as SavingsOffer)
const challenge = (over: Partial<SavingsChallenge> = {}): SavingsChallenge => ({ enrollment: null, accepted_plan: null, projection: null, offer: offer(), suggested_target_cents: 50_000, ...over })
beforeEach(() => vi.resetAllMocks())
afterEach(cleanup)

it('shows the join screen’s dates and terms, and joins only after the box and Accept', async () => {
  const onJoined = vi.fn(); const onDone = vi.fn()
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge())
  vi.mocked(enrollSavingsChallenge).mockResolvedValue({ record: {} as never, replayed: false, challenge: challenge() })
  render(<MiaJoinCard onJoined={onJoined} onDone={onDone} />)
  await screen.findByText(/Your 90 days: Thu, Nov 12 – Tue, Feb 9, 2027/)
  expect(screen.getByText(/You approve each amount; the app doesn’t move money/)).toBeTruthy()
  const accept = screen.getByRole('button', { name: 'Accept and join' }) as HTMLButtonElement
  expect(accept.disabled).toBe(true)
  fireEvent.click(accept)
  expect(enrollSavingsChallenge).not.toHaveBeenCalled()
  fireEvent.click(screen.getByLabelText('I’ve read this and accept joining the challenge.'))
  expect(accept.disabled).toBe(false)
  fireEvent.click(accept)
  await screen.findByRole('heading', { name: 'You’re in. Welcome to the challenge.' })
  expect(enrollSavingsChallenge).toHaveBeenCalledWith({ participation_accepted: true, policy_version: '1', late_start_accepted: false, expected_acceptance_digest: 'digest-1' }, expect.any(String))
  expect(onJoined).toHaveBeenCalledOnce()
})

it('needs the late-start box too when the group started earlier', async () => {
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge({ offer: offer({ late_start_acceptance_required: true }) }))
  render(<MiaJoinCard onJoined={vi.fn()} onDone={vi.fn()} />)
  await screen.findByText(/start later than the group’s/)
  fireEvent.click(screen.getByLabelText('I’ve read this and accept joining the challenge.'))
  expect((screen.getByRole('button', { name: 'Accept and join' }) as HTMLButtonElement).disabled).toBe(true)
  fireEvent.click(screen.getByLabelText(/start later than the group’s/))
  expect((screen.getByRole('button', { name: 'Accept and join' }) as HTMLButtonElement).disabled).toBe(false)
})

it('reuses one request key on a retry and asks her to check the boxes again when the details changed', async () => {
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge())
  vi.mocked(enrollSavingsChallenge).mockRejectedValueOnce(new Error('offline')).mockRejectedValueOnce(new ApiRequestError('changed', { status: 409 }))
  render(<MiaJoinCard onJoined={vi.fn()} onDone={vi.fn()} />)
  await screen.findByText(/Your 90 days/)
  fireEvent.click(screen.getByLabelText('I’ve read this and accept joining the challenge.'))
  fireEvent.click(screen.getByRole('button', { name: 'Accept and join' }))
  await screen.findByRole('alert')
  await waitFor(() => expect((screen.getByRole('button', { name: 'Accept and join' }) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button', { name: 'Accept and join' }))
  await screen.findByText(/joining details were updated/)
  const keys = vi.mocked(enrollSavingsChallenge).mock.calls.map(call => call[1])
  expect(keys[0]).toBe(keys[1])
  expect((screen.getByLabelText('I’ve read this and accept joining the challenge.') as HTMLInputElement).checked).toBe(false)
})

it('says so when the group is not taking members, and offers a retry when the details do not load', async () => {
  vi.mocked(fetchSavingsChallenge).mockResolvedValueOnce(challenge({ offer: offer({ accepting_enrollments: false }) }))
  const { unmount } = render(<MiaJoinCard onJoined={vi.fn()} onDone={vi.fn()} />)
  await screen.findByText('This group isn’t taking new members right now.')
  expect((screen.getByRole('button', { name: 'Accept and join' }) as HTMLButtonElement).disabled).toBe(true)
  unmount()
  vi.mocked(fetchSavingsChallenge).mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce(challenge())
  render(<MiaJoinCard onJoined={vi.fn()} onDone={vi.fn()} />)
  await screen.findByText(/couldn’t load the joining details/)
  fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
  await screen.findByText(/Your 90 days/)
})

it('does not offer joining to someone who is already in', async () => {
  const onJoined = vi.fn()
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge({ enrollment: { id: 9 } as never }))
  const { container } = render(<MiaJoinCard onJoined={onJoined} onDone={vi.fn()} />)
  await waitFor(() => expect(onJoined).toHaveBeenCalled())
  expect(container.textContent).toBe('')
})
