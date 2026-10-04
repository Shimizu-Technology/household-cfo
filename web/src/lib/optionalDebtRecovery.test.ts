// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from 'vitest'
import { debtFixtureScope } from '../test/optionalDebtFixtures'
import { debtRecoveryKey, clearDebtIdentity, readDebtIdentity, saveDebtIdentity } from './optionalDebtRecovery'
beforeEach(() => sessionStorage.clear())
describe('identity-only optional debt recovery', () => {
  it('persists four identities and original correction card ID but never financial extras', () => { saveDebtIdentity({ scope: { ...debtFixtureScope, label: 'Never store label' }, action: 'stage', key: 'original', cardId: 4, input: { balance_cents: 13337, apr: 'Never store APR' } } as Parameters<typeof saveDebtIdentity>[0]); const saved = sessionStorage.getItem(debtRecoveryKey)!; expect(saved).not.toContain('13337'); expect(saved).not.toContain('Never store'); expect(readDebtIdentity(debtFixtureScope)?.cardId).toBe(4) })
  it('does not expose or delete an original identity when another scope reads', () => { for (const key of ['user_id', 'household_id', 'cohort_id', 'enrollment_id'] as const) { saveDebtIdentity({ scope: debtFixtureScope, action: 'approve', draftId: 300, key: 'original' }); expect(readDebtIdentity({ ...debtFixtureScope, [key]: 999 })).toBeNull(); expect(readDebtIdentity(debtFixtureScope)?.key).toBe('original') } })
  it('requires original approval draft ID and sanitizes extra stored fields on read', () => { sessionStorage.setItem(debtRecoveryKey, JSON.stringify({ scope: debtFixtureScope, action: 'approve', key: 'original' })); expect(readDebtIdentity(debtFixtureScope)).toBeNull(); saveDebtIdentity({ scope: debtFixtureScope, action: 'approve', draftId: 300, key: 'original' }); expect(readDebtIdentity(debtFixtureScope)).toEqual({ scope: debtFixtureScope, action: 'approve', draftId: 300, key: 'original' }) })
})
it('retains A/B/A and clears only the matching original key', () => {
  const a = { scope: debtFixtureScope, action: 'stage' as const, key: 'nil-card-A' }, b = { scope: { ...debtFixtureScope, cohort_id: 702, enrollment_id: 101 }, action: 'stage' as const, key: 'nil-card-B' }
  expect(saveDebtIdentity(a)).toBe(true); expect(readDebtIdentity(b.scope)).toBeNull()
  expect(saveDebtIdentity(b)).toBe(true); expect(readDebtIdentity(a.scope)).toEqual(a)
  clearDebtIdentity({ ...a, key: 'foreign-key' }); expect(readDebtIdentity(a.scope)).toEqual(a)
  clearDebtIdentity(b); expect(readDebtIdentity(a.scope)).toEqual(a); expect(readDebtIdentity(b.scope)).toBeNull()
  expect(saveDebtIdentity({ ...a, key: 'duplicate-new-card' })).toBe(false)
})
it('preserves a valid foreign legacy identity while migrating and rejects scope-forged map entries', () => {
  const legacy = { scope: debtFixtureScope, action: 'stage' as const, key: 'legacy-A' }
  sessionStorage.setItem(debtRecoveryKey, JSON.stringify(legacy))
  const b = { ...legacy, scope: { ...debtFixtureScope, cohort_id: 702 }, key: 'B' }
  expect(readDebtIdentity(b.scope)).toBeNull(); expect(saveDebtIdentity(b)).toBe(true); expect(readDebtIdentity(debtFixtureScope)).toEqual(legacy)
  sessionStorage.setItem(debtRecoveryKey, JSON.stringify({ [Object.values(debtFixtureScope).join(':')]: b }))
  expect(readDebtIdentity(debtFixtureScope)).toBeNull()
})
