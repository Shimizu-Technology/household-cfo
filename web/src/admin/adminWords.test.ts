import { describe, expect, it } from 'vitest'
import type { AdminCohort, AdminUser } from '../api'
import { groupLine, inviteStateOf, lastActiveWords, setupWords } from './adminWords'

const person = (over: Partial<AdminUser> & { email_status?: string } = {}) => ({
  role: 'participant', invitation_status: 'pending', invite_email: { status: over.email_status ?? 'sent' }, workspace: { setup_status: 'complete', last_safe_activity_at: null }, ...over,
}) as unknown as AdminUser

describe('invite state in plain words', () => {
  it('maps each account to Joined, Invited, Bounced or Removed', () => {
    expect(inviteStateOf(person({ invitation_status: 'accepted' }))).toBe('joined')
    expect(inviteStateOf(person())).toBe('invited')
    expect(inviteStateOf(person({ email_status: 'failed' }))).toBe('bounced')
    expect(inviteStateOf(person({ invitation_status: 'revoked' }))).toBe('removed')
  })
  it('shows setup only for participants who have joined', () => {
    expect(setupWords(person({ invitation_status: 'accepted' }))).toBe('Setup done')
    expect(setupWords(person())).toBe('—')
    expect(setupWords(person({ role: 'coach', invitation_status: 'accepted' }))).toBe('—')
  })
})

describe('last active', () => {
  const now = new Date(2026, 10, 11, 12)
  it('says today, yesterday, days ago, a date, or not yet', () => {
    expect(lastActiveWords(new Date(2026, 10, 11, 8).toISOString(), now)).toBe('Today')
    expect(lastActiveWords(new Date(2026, 10, 10, 23).toISOString(), now)).toBe('Yesterday')
    expect(lastActiveWords(new Date(2026, 10, 8, 9).toISOString(), now)).toBe('3 days ago')
    expect(lastActiveWords(new Date(2026, 9, 1, 9).toISOString(), now)).toBe('Oct 1')
    expect(lastActiveWords(null, now)).toBe('Not yet')
  })
})

describe('group line', () => {
  const group = (over: Partial<AdminCohort>) => ({ id: 1, name: 'Bank of Guam 90 day savings', status: 'enrolling', starts_on: '2026-11-18', ends_on: null, ...over }) as AdminCohort
  const challenge = (state: string, enabled = true) => ({ enabled, state, capacity: 30 }) as AdminCohort['savings_challenge']
  const now = new Date(2026, 10, 11)
  it('reads like the brief: name, when it opens, how many joined', () => {
    expect(groupLine(group({ savings_challenge: challenge('open') }), 6, now)).toBe('Bank of Guam 90 day savings · opens Nov 18 · 6 of 30 joined')
    expect(groupLine(group({ starts_on: '2026-10-01', savings_challenge: challenge('paused') }), 6, now)).toBe('Bank of Guam 90 day savings · challenge paused · 6 of 30 joined')
  })
  it('does not talk about a challenge for a group that does not run one', () => {
    expect(groupLine(group({ name: 'Household', starts_on: '2026-10-01', status: 'active', savings_challenge: challenge('not_set_up', false) }), 2, now)).toBe('Household · running · 2 joined')
  })
})
