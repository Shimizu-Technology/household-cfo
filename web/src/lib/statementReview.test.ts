import { afterEach, describe, expect, it, vi } from 'vitest'
import { participantReviewFixture } from '../../e2e/sourceReviewFixtures'
import { APPROVE_PAGE, attentionEdit, answerInput, accountMatchNote, accountNames, accountSentence, accountsNeedingBasis, asBeforeNote, coverageQuestionText, lineKindFor, lineSheetForAnswer, lineSheetFromAttention, lineSheetWithDirection, parseLineAmount, readyCategoryLabel, spansYears, statementCounts, statementHeadline, type StatementPlan } from './statementReview'

const ready = (count: number): StatementPlan['ready'] => Array.from({ length: count }, (_, index) => ({ event_id: index, event_type: 'purchase' as const, category_id: 10, category_name: 'Groceries', as_before: false }))
const plan = (patch: Partial<StatementPlan> = {}): StatementPlan => ({ total: 27, done: 0, ready_event_ids: Array.from({ length: 24 }, (_, index) => index), ready: ready(24), coverage: { question: null, answer: null }, totals_check: 'matches', first_on: '2026-09-01', last_on: '2026-09-30',
  attention: [1, 2, 3].map((id) => ({ event_id: 100 + id, kind: 'refund' as const, event_type: 'refund' as const, question: 'Is this a refund?', answers: [], merchant: 'Amazon', posted_on: '2026-09-24', signed_amount_cents: 1299, category_id: null, category_name: null })), ...patch })
afterEach(() => vi.useRealTimers())
it('opens a pending exclusion on an approved purchase as left out', () => {
  const item = { ...plan().attention[0], kind: 'correction' as const, event_type: 'purchase' as const, disposition: 'exclude', signed_amount_cents: -1000 }
  expect(lineSheetFromAttention(item)).toMatchObject({ leftOut: true, kind: 'spending', amountCents: 1000 })
})

describe('a line whose direction she supplies', () => {
  const unsigned = (eventType: 'refund' | 'transfer' | 'cash_withdrawal') => ({ ...plan().attention[0], kind: 'direction' as never, event_type: eventType, signed_amount_cents: null, amount_cents: 10_000 })
  it('describes repeated monthly Apple Cash sections as one wallet', () => {
    const data = participantReviewFixture()
    const accounts = [{ ...data.accounts[0], id: 501 }, { ...data.accounts[0], id: 502 }]
    const names = { 501: { name: 'Apple Cash', last4: '6824' }, 502: { name: 'apple cash', last4: '6824' } }
    expect(statementHeadline(accounts, names, plan())).toContain('from Apple Cash ····6824')
    expect(statementHeadline(accounts, { ...names, 502: { ...names[502], last4: '1111' } }, plan())).toContain('from 2 accounts')
  })

  it('keeps a refund only as money in: the server refuses a refund that is money out', () => {
    expect(lineSheetWithDirection(unsigned('refund'), 'in')).toMatchObject({ kind: 'refund', moneyDirection: 'in' })
    expect(lineSheetWithDirection(unsigned('refund'), 'out')).toMatchObject({ kind: 'spending', moneyDirection: 'out' })
    expect(lineSheetWithDirection(unsigned('cash_withdrawal'), 'in')).toMatchObject({ kind: 'money_in', moneyDirection: 'in' })
  })
  it('opens an unsigned transfer from its row with the amount filled in and no direction chosen', () => {
    const sheet = lineSheetFromAttention(unsigned('transfer'))
    expect(sheet).toMatchObject({ directionRequired: true, amountCents: 10_000, kind: 'moved' })
    expect(sheet.moneyDirection).toBeUndefined()
  })
})

describe('the sheet her answer opens', () => {
  const asked = (kind: 'transfer' | 'card_payment' | 'refund' | 'unclear', eventType: 'transfer' | 'debt_payment' | 'refund' | 'unknown', cents: number) => ({ ...plan().attention[0], kind, event_type: eventType, signed_amount_cents: cents })
  it('opens on spending or money in after No, never on the kind she just said it is not', () => {
    expect(lineSheetForAnswer(asked('transfer', 'transfer', -10_000)).kind).toBe('spending')
    expect(lineSheetForAnswer(asked('transfer', 'transfer', 28_094)).kind).toBe('money_in')
    expect(lineSheetForAnswer(asked('card_payment', 'debt_payment', -43_653)).kind).toBe('spending')
    expect(lineSheetForAnswer(asked('refund', 'refund', 1_299)).kind).toBe('money_in')
  })
  it('opens a line the reader could not classify on the direction the statement shows', () => {
    expect(lineSheetForAnswer(asked('unclear', 'unknown', 172_020)).kind).toBe('money_in')
    expect(lineSheetForAnswer(asked('unclear', 'unknown', -5_463)).kind).toBe('spending')
    expect(lineKindFor('unknown', null)).toBe('spending')
  })
})

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
    const long = plan({ total: 1_010, ready: ready(1_000) })
    expect(APPROVE_PAGE).toBe(100)
    expect(statementCounts(long)).toMatchObject({ page: APPROVE_PAGE, sentence: '1,000 look right. 3 need a quick look. We’ll approve them 100 at a time.', action: 'Approve these 100' })
    expect(statementCounts(plan({ ...long, attention: [] })).sentence).toBe('All 1,000 look right. We’ll approve them 100 at a time.')
    expect(statementCounts(plan({ ready: ready(100) }))).toMatchObject({ page: 100, action: 'Approve the other 100' })
  })
  it('keeps saved lines with no category on her list and says they don’t count yet', () => {
    const uncategorized = (count: number) => plan().attention.slice(0, count).map((row) => ({ ...row, kind: 'no_category' as const, event_type: 'purchase' as const, question: 'What was this for?', signed_amount_cents: -1250 }))
    expect(statementCounts(plan({ total: 27, done: 27, ready: [], without_category: 1, attention: uncategorized(1) })))
      .toMatchObject({ attention: 1, sentence: 'All 27 lines are saved. 1 has no category yet, so it doesn’t count toward your spending.', action: null })
    expect(statementCounts(plan({ total: 27, done: 27, ready: [], without_category: 2, attention: uncategorized(2) })).sentence)
      .toBe('All 27 lines are saved. 2 have no category yet, so they don’t count toward your spending.')
    // A line that still needs another answer keeps the general wording.
    expect(statementCounts(plan({ total: 27, done: 26, ready: [], without_category: 1, attention: [...uncategorized(1), plan().attention[2]] })).sentence).toBe('26 saved. 2 still need a quick look.')
  })
  it('shows years on dates only when a file runs across a new year', () => {
    expect(spansYears(plan())).toBe(false)
    expect(spansYears(plan({ first_on: '2025-11-03', last_on: '2026-11-13' }))).toBe(true)
    expect(spansYears(plan({ first_on: null, last_on: '2026-11-13' }))).toBe(false)
  })
  it('re-asks about missing lines in plain words when the statement no longer asks', () => {
    expect(coverageQuestionText(plan({ coverage: { question: 'Is anything missing?', answer: null } }))).toBe('Is anything missing?')
    expect(coverageQuestionText(plan({ coverage: { question: null, answer: 'something_missing' } }))).toBe('You said something may be missing from this statement. Is anything still missing?')
  })
  it('writes long counts with a thousands separator', () => {
    expect(statementHeadline([], {}, plan({ total: 1_000, first_on: null, last_on: null }))).toBe('1,000 lines from your statement.')
    expect(statementCounts(plan({ total: 1_000, ready: [], attention: [], done: 1_000 })).sentence).toBe('All 1,000 lines are saved.')
  })
  it('says how many look right and how many need a look, and names the one action', () => {
    expect(statementCounts(plan())).toMatchObject({ sentence: '24 look right. 3 need a quick look.', action: 'Approve the other 24' })
    expect(statementCounts(plan({ attention: [] }))).toMatchObject({ sentence: 'All 24 look right.', action: 'Approve all 24' })
    expect(statementCounts(plan({ ready: ready(1), attention: plan().attention.slice(0, 1) }))).toMatchObject({ sentence: '1 look right. 1 needs a quick look.', action: 'Approve the other one' })
    expect(statementCounts(plan({ ready: [], done: 24 }))).toMatchObject({ sentence: '24 saved. 3 still need a quick look.', action: null })
    expect(statementCounts(plan({ ready: [], attention: [], done: 27 }))).toMatchObject({ sentence: 'All 27 lines are saved.', action: null })
  })
  it('says which category she did not see a guess for, in the summary and in the list', () => {
    const before = { event_id: 9, event_type: 'purchase' as const, category_id: 31, category_name: 'Dining out', as_before: true }
    expect(readyCategoryLabel(before)).toBe('Dining out · as before')
    expect(readyCategoryLabel({ ...before, as_before: false })).toBe('Dining out')
    expect(readyCategoryLabel({ ...before, category_id: null, category_name: null })).toBeNull()
    expect(asBeforeNote(plan())).toBeNull()
    expect(asBeforeNote(plan({ ready: [before, { ...before, event_id: 10 }, { ...ready(1)[0], event_id: 11 }] }))).toBe('2 use a category you chose before: Dining out.')
    expect(asBeforeNote(plan({ ready: [before] }))).toBe('1 uses a category you chose before: Dining out.')
    const names = ['A', 'B', 'C', 'D'].map((name, index) => ({ ...before, event_id: index, category_name: name }))
    expect(asBeforeNote(plan({ ready: names }))).toBe('4 lines use categories you chose before.')
    expect(asBeforeNote(plan({ ready: names.slice(0, 3) }))).toBe('3 use a category you chose before: A, B, C.')
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


it('does not describe multiple saved accounts by just the one with last four', () => {
  const first = participantReviewFixture().participant_review!.accounts[0]
  const approved = first.approved!
  const numbered = { ...first, last4: '6824' }
  const unnamed = { ...first, source_account_id: 502, last4: null,
    approved: { ...approved, tracked_account: { ...approved.tracked_account, id: approved.tracked_account.id + 1 } } }
  expect(accountMatchNote([numbered])).toBe('Saved with your account ending 6824')
  expect(accountMatchNote([numbered, unnamed])).toBe('')
})

// Ownership is an explicit answer, distinct from accepting the reader's classification.
it('sends the person-payment answer and the exact matching transfer she saw', () => {
  const item = { event_id: 91, kind: 'person_payment', event_type: 'transfer', question: 'Your own account or someone else?', answers: [], merchant: 'Zelle to Lina Talun', posted_on: '2026-07-07', signed_amount_cents: -2500, category_id: null, category_name: null } as const
  expect(answerInput({ ...item, answers: [] }, 'someone_else').lines[0]).toMatchObject({ decision: 'someone_else', shown: { event_type: 'transfer', category_id: null } })
  expect(answerInput({ ...item, answers: [] }, 'own_account').lines[0].decision).toBe('own_account')
  const unresolved = { ...item, answers: [], kind: 'direction' as const, recipient_question: true, signed_amount_cents: null }
  expect(lineSheetWithDirection(unresolved, 'out').recipientQuestion).toBe(true)
  expect(lineSheetWithDirection(unresolved, 'in').recipientQuestion).toBe(true)
  const pair = { event_id: 92, approved_version_id: null, account_version_id: 12, account: 'Talun Savings ending 4412', posted_on: '2026-07-08', signed_amount_cents: 2500 }
  expect(answerInput({ ...item, answers: [], kind: 'transfer_pair', transfer_pair: pair }, 'pair_transfer').lines[0]).toMatchObject({ decision: 'pair_transfer', transfer_pair: pair })
})

it('uses saved bank wording in category answers and line sheets while keeping the cleaned label', () => {
  const item = { ...plan().attention[0], merchant: '1776 COFFEE', editable_merchant: 'CARD PURCHASE 1776 COFFEE' }
  expect(attentionEdit(item, 10).merchant).toBe('CARD PURCHASE 1776 COFFEE')
  expect(lineSheetFromAttention(item).merchant).toBe('CARD PURCHASE 1776 COFFEE')
  expect(item.merchant).toBe('1776 COFFEE')
})
