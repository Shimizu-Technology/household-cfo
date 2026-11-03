import { afterEach, describe, expect, it, vi } from 'vitest'
import { participantReviewFixture } from '../../e2e/sourceReviewFixtures'
import { APPROVE_PAGE, accountNames, accountSentence, accountsNeedingBasis, lineKindFor, parseLineAmount, statementCounts, statementHeadline, totalsNote, type StatementPlan } from './statementReview'

const plan = (patch: Partial<StatementPlan> = {}): StatementPlan => ({ total: 27, done: 0, ready_event_ids: Array.from({ length: 24 }, (_, index) => index), totals_check: 'matches', first_on: '2026-09-01', last_on: '2026-09-30',
  attention: [1, 2, 3].map((id) => ({ event_id: 100 + id, kind: 'refund' as const, event_type: 'refund' as const, question: 'Is this a refund?', answers: [], merchant: 'Amazon', posted_on: '2026-09-24', signed_amount_cents: 1299, category_id: null, category_name: null })), ...patch })
afterEach(() => vi.useRealTimers())

describe('statement review wording', () => {
  it('names the lines, account and dates in one sentence', () => {
    vi.useFakeTimers({ now: new Date('2026-10-05T12:00:00Z'), toFake: ['Date'] })
    const data = participantReviewFixture(); const names = accountNames(data.accounts, data.participant_review!.accounts)
    expect(statementHeadline(data.accounts, { 501: { name: 'Bank of Guam', last4: '1234' } }, plan())).toBe('27 lines from Bank of Guam ····1234, Sep 1–30.')
    expect(names[501]).toEqual({ name: 'Fictional checking', last4: '' })
    expect(statementHeadline([], {}, plan({ total: 1, first_on: null, last_on: null }))).toBe('1 line from your statement.')
  })
  it('never names an account with a system label: the bank when known, else the last four, else just the statement', () => {
    const data = participantReviewFixture()
    const say = (name: string | null, last4: string | null) => statementHeadline(data.accounts, accountNames(data.accounts, [{ source_account_id: 501, name, last4 }]), plan({ first_on: null, last_on: null }))
    data.accounts[0].period_start_on = null; data.accounts[0].period_end_on = null
    expect(say(null, null)).toBe('27 lines from your statement.')
    expect(say(null, '1234')).toBe('27 lines from your account ····1234.')
    expect(say('Bank of Guam checking', '1234')).toBe('27 lines from Bank of Guam checking ····1234.')
    expect(accountSentence(undefined)).toBe('')
    expect(statementHeadline([data.accounts[0], { ...data.accounts[0], id: 502 }], {}, plan())).toContain('2 accounts')
  })
  it('approves a long statement a page at a time and says so', () => {
    const long = plan({ total: 1_010, ready_event_ids: Array.from({ length: 1_000 }, (_, index) => index) })
    expect(statementCounts(long)).toMatchObject({ page: APPROVE_PAGE, sentence: '1,000 look right. 3 need a quick look. We’ll approve them 400 at a time.', action: 'Approve these 400' })
    expect(statementCounts(plan({ ...long, attention: [] })).sentence).toBe('All 1,000 look right. We’ll approve them 400 at a time.')
    expect(statementCounts(plan({ ready_event_ids: Array.from({ length: 400 }, (_, index) => index) }))).toMatchObject({ page: 400, action: 'Approve the other 400' })
  })
  it('writes long counts with a thousands separator', () => {
    expect(statementHeadline([], {}, plan({ total: 1_000, first_on: null, last_on: null }))).toBe('1,000 lines from your statement.')
    expect(statementCounts(plan({ total: 1_000, ready_event_ids: [], attention: [], done: 1_000 })).sentence).toBe('All 1,000 lines are saved.')
  })
  it('says how many look right and how many need a look, and names the one action', () => {
    expect(statementCounts(plan())).toMatchObject({ sentence: '24 look right. 3 need a quick look.', action: 'Approve the other 24' })
    expect(statementCounts(plan({ attention: [] }))).toMatchObject({ sentence: 'All 24 look right.', action: 'Approve all 24' })
    expect(statementCounts(plan({ ready_event_ids: [1], attention: plan().attention.slice(0, 1) }))).toMatchObject({ sentence: '1 look right. 1 needs a quick look.', action: 'Approve the other one' })
    expect(statementCounts(plan({ ready_event_ids: [], done: 24 }))).toMatchObject({ sentence: '24 saved. 3 still need a quick look.', action: null })
    expect(statementCounts(plan({ ready_event_ids: [], attention: [], done: 27 }))).toMatchObject({ sentence: 'All 27 lines are saved.', action: null })
  })
  it('keeps uncertainty visible: a mismatch and an unchecked file are both said, a match is quiet', () => {
    expect(totalsNote('mismatch')).toContain('don’t add up')
    expect(totalsNote('count')).toContain('number of lines')
    expect(totalsNote('unchecked')).toContain('couldn’t check')
    expect(totalsNote('matches')).toBeNull()
  })
})

describe('statement review inputs', () => {
  it('reads an amount a person would type and never turns a blank or bad one into zero', () => {
    expect(parseLineAmount('12.5')).toBe(1250)
    expect(parseLineAmount('$1,250.00')).toBe(125000)
    expect(parseLineAmount('')).toBeNull()
    expect(parseLineAmount('0')).toBeNull()
    expect(parseLineAmount('-4')).toBeNull()
    expect(parseLineAmount('12.345')).toBeNull()
  })
  it('maps a line to what a person would call it', () => {
    expect(lineKindFor('purchase', -500)).toBe('spending')
    expect(lineKindFor('fee', -500)).toBe('spending')
    expect(lineKindFor('income', 500)).toBe('money_in')
    expect(lineKindFor('interest', 25)).toBe('money_in')
    expect(lineKindFor('debt_payment', -500)).toBe('card')
    expect(lineKindFor('cash_withdrawal', -500)).toBe('cash')
    expect(lineKindFor('transfer', -500)).toBe('moved')
  })
  it('asks about an account only while its type is unknown and unreviewed', () => {
    const data = participantReviewFixture(); data.accounts[0].account_basis = 'unknown'
    expect(accountsNeedingBasis(data.accounts, [{ source_account_id: 501, approved: null }])).toHaveLength(1)
    expect(accountsNeedingBasis(data.accounts, [{ source_account_id: 501, approved: {} }])).toHaveLength(0)
  })
})
