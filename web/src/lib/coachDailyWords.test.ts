import { describe, expect, it } from 'vitest'
import { householdStatus, savingsStatus } from './coachDailyWords'
import type { CoachDailyPerson } from './coachChallengeApi'

const person = (over: Partial<CoachDailyPerson>) => ({ membership_status: 'joined', enrollment_id: null, setup_status: 'complete', check_in: null, ...over }) as unknown as CoachDailyPerson

describe('savings status in plain words', () => {
  it('says removed access instead of joined when the seat was revoked before the challenge started', () => {
    expect(savingsStatus(person({ membership_status: 'revoked' }))).toBe('Account access removed')
    expect(householdStatus(person({ membership_status: 'revoked' }))).toBe('Account access removed')
  })
  it('keeps the invited and joined wording for people who have no challenge yet', () => {
    expect(savingsStatus(person({ membership_status: 'invited' }))).toBe('Invited · Hasn’t joined yet')
    expect(savingsStatus(person({}))).toBe('Joined · Hasn’t started the challenge')
  })
})
