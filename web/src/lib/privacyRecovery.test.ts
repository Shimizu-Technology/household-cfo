// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from 'vitest'
import { readPrivacyRecovery, savePrivacyRecovery } from './privacyRecovery'
import { privacyScope } from '../test/privacyFixtures'
beforeEach(() => sessionStorage.clear())
describe('identity-only private request recovery', () => {
  it('persists only actor and request identity even if an object contains private extras', () => {
    const identity = { scope: privacyScope, enrollmentId: 100, key: 'same-key', action: 'support_request' as const, input: { message: 'never store this', selected_records: [{ record_id: 99 }] } }
    savePrivacyRecovery(identity)
    expect(sessionStorage.getItem('challenge-private-request-identity-v1')).not.toContain('never store this')
    expect(sessionStorage.getItem('challenge-private-request-identity-v1')).not.toContain('selected_records')
    expect(readPrivacyRecovery(privacyScope)).toEqual({ scope: privacyScope, enrollmentId: 100, key: 'same-key', action: 'support_request' })
  })
  it('keeps scoped recovery across user or household switch', () => {
    savePrivacyRecovery({ scope: privacyScope, enrollmentId: 100, action: 'consent', key: 'old-user' })
    expect(readPrivacyRecovery({ ...privacyScope, user_id: 999 })).toBeNull()
    expect(readPrivacyRecovery(privacyScope)?.key).toBeTruthy()
    savePrivacyRecovery({ scope: privacyScope, enrollmentId: 100, action: 'consent', key: 'old-user' })
    expect(readPrivacyRecovery({ ...privacyScope, household_id: 999 })).toBeNull()
    expect(readPrivacyRecovery(privacyScope)?.key).toBeTruthy()
  })
  it('retains reflection route identity but never text or financial facts', () => {
    savePrivacyRecovery({ scope: privacyScope, enrollmentId: 100, action: 'erase', key: 'erase-once', reflectionId: 700 })
    expect(readPrivacyRecovery(privacyScope)?.reflectionId).toBe(700)
  })
})
