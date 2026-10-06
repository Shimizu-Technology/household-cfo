import { describe, expect, it } from 'vitest'
import { moneyTopicForOperation } from './moneyNavigation'

describe('manual financial destinations', () => {
  it('keeps income records and future schedules in the same destination', () => {
    expect(moneyTopicForOperation('income.source.update')).toBe('income')
    expect(moneyTopicForOperation('income.schedule.create')).toBe('income')
  })
  it('routes legacy financial items without changing their saved review metadata', () => {
    expect(moneyTopicForOperation('', 'update_debt')).toBe('debt')
    expect(moneyTopicForOperation('account.reconcile', 'reconcile_plaid_account')).toBe('accounts')
    expect(moneyTopicForOperation('goal.record.archive')).toBe('goals')
  })
  it('preserves profile policy and budget editor destinations', () => {
    expect(moneyTopicForOperation('goal.runway_policy.update', 'update_runway_policy')).toBeNull()
    expect(moneyTopicForOperation('goal.transition_policy.update', 'update_transition_policy')).toBeNull()
    expect(moneyTopicForOperation('profile.update')).toBeNull()
    expect(moneyTopicForOperation('budget.category.update')).toBeNull()
  })
})
