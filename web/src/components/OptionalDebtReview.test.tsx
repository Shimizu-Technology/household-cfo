// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError } from '../api'
import { OptionalDebtReview } from './OptionalDebtReview'
import { OptionalDebtTerms } from './OptionalDebtTerms'
import { debtEnvelope, debtFixtureScope, fictionalDraft, fictionalVersion, fictionalHouseholdCandidate, fictionalCandidate, syntheticDebtApi } from '../test/optionalDebtFixtures'
import { debtRecoveryKey, saveDebtIdentity } from '../lib/optionalDebtRecovery'
import type { DebtInput, OptionalDebtApi } from '../lib/optionalDebt'
beforeEach(() => sessionStorage.clear())
afterEach(cleanup)
const open = (api = syntheticDebtApi()) => render(<OptionalDebtReview actorScope={debtFixtureScope} cohortId={701} onClose={vi.fn()} api={api}/> )
async function enterProposal(label = 'Private fictional label') { fireEvent.click(await screen.findByRole('button', { name: 'Add optional card terms' })); fireEvent.change(screen.getByLabelText('How will you review these terms?'), { target: { value: 'manual' } }); fireEvent.change(screen.getByLabelText('Card label'), { target: { value: label } }); fireEvent.click(screen.getByRole('button', { name: 'Review pending proposal' })) }
async function stage() { await enterProposal(); fireEvent.click(screen.getByRole('checkbox', { name: 'I reviewed this exact pending proposal and mapping choice.' })); fireEvent.click(screen.getByRole('button', { name: 'Save pending proposal' })) }
describe('optional private card review', () => {
  it('requires explicit pending review, preserves unknowns and approves only a separately selected draft', async () => { const api = syntheticDebtApi(); api.mutate = vi.fn(api.mutate); open(api); await enterProposal(); expect(api.mutate).not.toHaveBeenCalled(); expect((screen.getByRole('button', { name: 'Save pending proposal' }) as HTMLButtonElement).disabled).toBe(true); fireEvent.click(screen.getByRole('checkbox', { name: 'I reviewed this exact pending proposal and mapping choice.' })); fireEvent.click(screen.getByRole('button', { name: 'Save pending proposal' })); await screen.findByText('Pending proposal saved. Review it separately before approving.'); expect(vi.mocked(api.mutate).mock.calls[0][2]).toEqual(expect.objectContaining({ terms: expect.objectContaining({ balance_cents: null, minimum_payment_cents: null, apr_bps: null }), source_mapping: null })); fireEvent.click(await screen.findByRole('button', { name: 'Review approval for draft 300' })); await screen.findByRole('heading', { name: 'Review before approving card terms' }); expect((screen.getByRole('button', { name: 'Approve reviewed card terms' }) as HTMLButtonElement).disabled).toBe(true); fireEvent.click(screen.getByRole('checkbox', { name: 'I accept these exact reviewed card terms and mapping.' })); fireEvent.click(screen.getByRole('button', { name: 'Approve reviewed card terms' })); await screen.findByText('Card terms approved. Your savings are unchanged.'); expect(vi.mocked(api.mutate).mock.calls[1][1]).toBe('approve') })
  it('shows unknown and known zero without inferring a full portfolio or extra payment', async () => { open(); await screen.findByText('Fictional paid-off card'); const records = screen.getByRole('region', { name: 'Optional card records' }); expect(within(records).getAllByText('$0.00')).toHaveLength(2); expect(within(records).getAllByText('Unknown').length).toBeGreaterThan(0); expect(screen.getByText(/No extra-payment amount or payoff date/)).toBeTruthy(); const order = screen.getByRole('region', { name: 'Qualified card comparison' }); expect(within(order).queryByText('Fictional paid-off card')).toBeNull(); expect(within(order).queryByText('Fictional unknown balance')).toBeNull() })
  it('explicitly selects source mapping and resets invented APR/minimum when another account is selected', async () => { const api = syntheticDebtApi(); api.mutate = vi.fn(api.mutate); open(api); fireEvent.click(await screen.findByRole('button', { name: 'Add optional card terms' })); fireEvent.change(screen.getByLabelText('APR in percent'), { target: { value: '19.99' } }); fireEvent.change(screen.getByLabelText('How will you review these terms?'), { target: { value: 'source' } }); fireEvent.change(screen.getByLabelText('Exact approved liability account'), { target: { value: '901' } }); expect((screen.getByLabelText('APR in percent') as HTMLInputElement).value).toBe(''); expect((screen.getByLabelText('Balance in US dollars') as HTMLInputElement).value).toBe('870.00'); fireEvent.click(screen.getByRole('button', { name: 'Review pending proposal' })); const proposal = screen.getByRole('region', { name: 'Pending proposal review' }); expect(within(proposal).getByText('$870.00')).toBeTruthy(); expect(within(proposal).getAllByText('Unknown').length).toBeGreaterThan(0) })
  it('recovery checks status before same-key exact retry and stores no label or terms', async () => { const api = syntheticDebtApi(), original = api.mutate; api.mutate = vi.fn().mockRejectedValueOnce(new Error('lost response')).mockImplementation(original); api.status = vi.fn(api.status); open(api); await stage(); await screen.findByText('lost response'); expect(screen.queryByRole('button', { name: 'Retry exact card request' })).toBeNull(); const identity = sessionStorage.getItem(debtRecoveryKey)!; expect(identity).not.toContain('Private fictional label'); expect(identity).not.toContain('terms'); fireEvent.click(screen.getByRole('button', { name: 'Check earlier card result' })); fireEvent.click(await screen.findByRole('button', { name: 'Retry exact card request' })); await screen.findByText('Pending proposal saved. Review it separately before approving.'); const calls = vi.mocked(api.mutate).mock.calls; expect(calls[1].slice(0, 4)).toEqual(calls[0].slice(0, 4)); expect(sessionStorage.getItem(debtRecoveryKey)).toBeNull() })
  it('cold original approval is re-reviewed from authorized server facts with its original draft and key', async () => { saveDebtIdentity({ scope: debtFixtureScope, action: 'approve', draftId: 300, key: 'cold-original' }); const api = syntheticDebtApi({ pending: true }); api.mutate = vi.fn(api.mutate); open(api); fireEvent.click(await screen.findByRole('button', { name: 'Check earlier card result' })); fireEvent.click(await screen.findByRole('checkbox', { name: 'I will re-review this same action using its original request key.' })); fireEvent.click(screen.getByRole('button', { name: 'Prepare original request review' })); await screen.findByRole('heading', { name: 'Review before approving card terms' }); fireEvent.click(screen.getByRole('checkbox', { name: 'I accept these exact reviewed card terms and mapping.' })); fireEvent.click(screen.getByRole('button', { name: 'Approve reviewed card terms' })); await waitFor(() => expect(api.mutate).toHaveBeenCalledWith(debtFixtureScope, 'approve', expect.objectContaining({ draft_id: 300 }), 'cold-original', expect.any(AbortSignal))) })
  it('nil enrollment in-flight status retains only identity and cannot display a committed foreign record', async () => { saveDebtIdentity({ scope: debtFixtureScope, action: 'stage', key: 'original' }); const api = syntheticDebtApi(); api.status = vi.fn().mockResolvedValueOnce({ ...debtEnvelope, enrollment_id: null, state: 'in_flight' }).mockResolvedValue({ ...debtEnvelope, enrollment_id: 999, state: 'committed', record: fictionalDraft(300, 4), replayed: true }); open(api); fireEvent.click(await screen.findByRole('button', { name: 'Check earlier card result' })); await screen.findByText('Your earlier request is still processing. Check again.'); expect(sessionStorage.getItem(debtRecoveryKey)).toContain('original'); fireEvent.click(screen.getByRole('button', { name: 'Check earlier card result' })); await screen.findByText(/Financial details have been cleared/); expect(screen.queryByText('Fictional paid-off card')).toBeNull(); expect(sessionStorage.getItem(debtRecoveryKey)).toContain('original') })
  it('clears private buffers on fresh forbidden response and actor switch', async () => { const api = syntheticDebtApi(); const view = open(api); await screen.findByText('Fictional paid-off card'); api.summary = vi.fn().mockRejectedValue(new ApiRequestError('Held now', { status: 403 })); fireEvent.click(screen.getByRole('button', { name: 'Refresh card review' })); await screen.findByText(/Financial details have been cleared/); expect(screen.queryByText('Fictional paid-off card')).toBeNull(); view.rerender(<OptionalDebtReview actorScope={{ ...debtFixtureScope, user_id: 999 }} cohortId={701} onClose={vi.fn()} api={api}/>); expect(screen.queryByText('Fictional paid-off card')).toBeNull() })
  it('pages all card identities and history and requires a reason against the captured correction head', async () => { const api = syntheticDebtApi({ pageSize: 1 }); api.mutate = vi.fn(api.mutate); open(api); await screen.findByRole('button', { name: 'Review correction for card 1' }); fireEvent.click(screen.getByRole('button', { name: 'Next cards' })); fireEvent.click(await screen.findByRole('button', { name: 'Review correction for card 2' })); fireEvent.change(screen.getByLabelText('How will you review these terms?'), { target: { value: 'manual' } }); fireEvent.click(screen.getByRole('button', { name: 'Review pending proposal' })); expect(screen.getByText('Explain this correction before reviewing it.')).toBeTruthy(); fireEvent.change(screen.getByLabelText('Reason for this review (required for correction)'), { target: { value: 'Reviewed a real zero' } }); fireEvent.click(screen.getByRole('button', { name: 'Review pending proposal' })); fireEvent.click(screen.getByRole('checkbox', { name: 'I reviewed this exact pending proposal and mapping choice.' })); fireEvent.click(screen.getByRole('button', { name: 'Save pending proposal' })); await waitFor(() => expect(api.mutate).toHaveBeenCalledWith(expect.anything(), 'stage', expect.objectContaining({ card_id: 2, expected_version_id: 20, expected_head_lock_version: 1, terms: expect.objectContaining({ balance_cents: 0 }) }), expect.any(String), expect.anything())) })
  it('blocks financial submission when identity storage is unavailable', async () => {
    const api = syntheticDebtApi(); api.mutate = vi.fn(api.mutate); open(api); await enterProposal()
    const storage = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('blocked storage') })
    try { fireEvent.click(screen.getByRole('checkbox', { name: 'I reviewed this exact pending proposal and mapping choice.' })); fireEvent.click(screen.getByRole('button', { name: 'Save pending proposal' })); await screen.findByText(/No card change was submitted/); expect(api.mutate).not.toHaveBeenCalled() } finally { storage.mockRestore() }
  })
  it('ignores delayed old-actor pages after a remount and never restores their financial labels', async () => {
    const api = syntheticDebtApi(), original = api.records
    let release!: () => void
    const delayed = new Promise<void>(resolve => { release = resolve })
    api.records = vi.fn(async (...args: Parameters<typeof original>) => { const result = await original(...args); await delayed; return result }) as typeof original
    const view = open(api); await waitFor(() => expect(api.records).toHaveBeenCalled())
    const next = syntheticDebtApi({ empty: true }), summary = await next.summary(701)
    next.summary = async () => ({ ...summary, actor_scope: { ...summary.actor_scope, user_id: 999 } })
    const rows = next.records; next.records = async (...args) => ({ ...await rows(...args), actor_scope: { ...debtEnvelope.actor_scope, user_id: 999 } })
    const candidates = next.candidates; next.candidates = async (...args) => ({ ...await candidates(...args), actor_scope: { ...debtEnvelope.actor_scope, user_id: 999 } })
    const householdCandidates = next.householdCandidates; next.householdCandidates = async (...args) => ({ ...await householdCandidates(...args), actor_scope: { ...debtEnvelope.actor_scope, user_id: 999 } })
    view.rerender(<OptionalDebtReview actorScope={{ ...debtFixtureScope, user_id: 999 }} cohortId={701} onClose={vi.fn()} api={next}/>)
    await screen.findByText('No optional card terms approved yet. Having no debt is a valid starting point.'); release()
    await waitFor(() => expect(screen.queryByText('Fictional paid-off card')).toBeNull())
  })
  it('blocks fresh malformed decimals and paid-off unknowns before network writes', async () => { const api = syntheticDebtApi(); api.mutate = vi.fn(api.mutate); open(api); await enterProposal(); fireEvent.click(screen.getByRole('button', { name: 'Back to terms' })); fireEvent.change(screen.getByLabelText('Balance in US dollars'), { target: { value: '1.001' } }); fireEvent.click(screen.getByRole('button', { name: 'Review pending proposal' })); expect(screen.getByText(/at most two decimal places/)).toBeTruthy(); expect(api.mutate).not.toHaveBeenCalled() })
  it('does not abandon an original unknown approval when a recovered submission conflicts', async () => { saveDebtIdentity({ scope: debtFixtureScope, action: 'approve', draftId: 300, key: 'cold-conflict' }); const api = syntheticDebtApi({ pending: true }); api.mutate = vi.fn().mockRejectedValue(new ApiRequestError('Original request conflicts', { status: 409 })); open(api); fireEvent.click(await screen.findByRole('button', { name: 'Check earlier card result' })); fireEvent.click(await screen.findByRole('checkbox', { name: 'I will re-review this same action using its original request key.' })); fireEvent.click(screen.getByRole('button', { name: 'Prepare original request review' })); await screen.findByRole('heading', { name: 'Review before approving card terms' }); fireEvent.click(screen.getByRole('checkbox', { name: 'I accept these exact reviewed card terms and mapping.' })); fireEvent.click(screen.getByRole('button', { name: 'Approve reviewed card terms' })); await screen.findByText('Original request conflicts'); expect(sessionStorage.getItem(debtRecoveryKey)).toContain('cold-conflict'); expect(screen.getByRole('button', { name: 'Check earlier card result' })).toBeTruthy() })
})
export type { DebtInput, OptionalDebtApi }
it('program A/B/A retains uncertain new-card stage identity and cannot start a duplicate card', async () => {
  const a = syntheticDebtApi(); a.mutate = vi.fn().mockRejectedValue(new Error('A result uncertain'))
  const view = open(a); await stage(); await screen.findByText('A result uncertain')
  const originalKey = vi.mocked(a.mutate).mock.calls[0][3]
  const b = syntheticDebtApi({ empty: true }), summary = b.summary, records = b.records, candidates = b.candidates
  b.summary = async (...args) => ({ ...await summary(...args), cohort_id: 702, enrollment_id: 802 })
  b.records = async (...args) => ({ ...await records(...args), cohort_id: 702, enrollment_id: 802 })
  b.candidates = async (...args) => ({ ...await candidates(...args), cohort_id: 702, enrollment_id: 802 })
  const householdCandidates = b.householdCandidates; b.householdCandidates = async (...args) => ({ ...await householdCandidates(...args), cohort_id: 702, enrollment_id: 802 })
  view.rerender(<OptionalDebtReview actorScope={debtFixtureScope} cohortId={702} onClose={vi.fn()} api={b}/>)
  await screen.findByText('No optional card terms approved yet. Having no debt is a valid starting point.'); expect(screen.queryByRole('button', { name: 'Check earlier card result' })).toBeNull()
  view.rerender(<OptionalDebtReview actorScope={debtFixtureScope} cohortId={701} onClose={vi.fn()} api={a}/>)
  await screen.findByRole('button', { name: 'Check earlier card result' }); expect(sessionStorage.getItem(debtRecoveryKey)).toContain(originalKey)
  expect((screen.getByRole('button', { name: 'Add optional card terms' }) as HTMLButtonElement).disabled).toBe(true); expect(a.mutate).toHaveBeenCalledOnce(); expect(screen.queryByDisplayValue('Private fictional label')).toBeNull()
})

it('links a saved household card only through a pending proposal and separate approval, retaining zero and unknown values', async () => {
  const api = syntheticDebtApi({ empty: true }); api.mutate = vi.fn(api.mutate); open(api)
  fireEvent.click(await screen.findByRole('button', { name: 'Add optional card terms' }))
  fireEvent.change(screen.getByLabelText('How will you review these terms?'), { target: { value: 'household' } })
  fireEvent.change(screen.getByLabelText('Saved household credit card'), { target: { value: '950' } })
  expect((screen.getByLabelText('Balance in US dollars') as HTMLInputElement).value).toBe('420.00')
  expect((screen.getByLabelText('Required minimum in US dollars') as HTMLInputElement).value).toBe('0.00')
  expect((screen.getByLabelText('APR in percent') as HTMLInputElement).value).toBe('')
  fireEvent.click(screen.getByRole('button', { name: 'Review pending proposal' }))
  expect(api.mutate).not.toHaveBeenCalled()
  expect(screen.getByText(/Link to Fictional saved household card; household values stay unchanged/)).toBeTruthy()
  fireEvent.click(screen.getByRole('checkbox', { name: 'I reviewed this exact pending proposal and mapping choice.' }))
  fireEvent.click(screen.getByRole('button', { name: 'Save pending proposal' }))
  await screen.findByText('Pending proposal saved. Review it separately before approving.')
  expect(vi.mocked(api.mutate).mock.calls[0][2]).toEqual(expect.objectContaining({ household_debt_mapping: { household_debt_id: 950, fingerprint: 'c'.repeat(64) }, terms: expect.objectContaining({ minimum_payment_cents: 0, apr_bps: null }) }))
  fireEvent.click(await screen.findByRole('button', { name: 'Review approval for draft 300' }))
  await screen.findByRole('heading', { name: 'Review before approving card terms' })
  expect(screen.getByText(/Its reviewed snapshot is retained; household values stay unchanged/)).toBeTruthy()
  fireEvent.click(screen.getByRole('checkbox', { name: 'I accept these exact reviewed card terms and mapping.' }))
  fireEvent.click(screen.getByRole('button', { name: 'Approve reviewed card terms' }))
  await screen.findByRole('button', { name: 'Review current household terms for Fictional saved household card' })
  fireEvent.click(screen.getByRole('button', { name: 'Review current household terms for Fictional saved household card' }))
  expect((screen.getByLabelText('Saved household credit card') as HTMLSelectElement).value).toBe('950')
  fireEvent.click(screen.getByRole('button', { name: 'Review pending proposal' }))
  expect(screen.getByText('Explain this correction before reviewing it.')).toBeTruthy()
})
it('rejects a foreign household candidate envelope before displaying saved financial facts', async () => {
  const api = syntheticDebtApi(); api.householdCandidates = async () => ({ ...debtEnvelope, actor_scope: { ...debtEnvelope.actor_scope, household_id: 999 }, records: [], next_cursor: null })
  open(api); await screen.findByText(/Financial details have been cleared/)
  expect(screen.queryByText('Fictional paid-off card')).toBeNull()
})
it('shows a changed saved household snapshot and disables approval until a fresh proposal is reviewed', async () => {
  const api = syntheticDebtApi({ empty: true }), mutate = api.mutate, candidates = api.householdCandidates
  let changed = false
  api.mutate = async (...args) => { const result = await mutate(...args); if (args[1] === 'stage') changed = true; return result }
  api.householdCandidates = async (...args) => { const page = await candidates(...args); return { ...page, records: page.records.map(row => ({ ...row, fingerprint: changed ? 'd'.repeat(64) : row.fingerprint })) } }
  open(api)
  fireEvent.click(await screen.findByRole('button', { name: 'Add optional card terms' }))
  fireEvent.change(screen.getByLabelText('How will you review these terms?'), { target: { value: 'household' } })
  fireEvent.change(screen.getByLabelText('Saved household credit card'), { target: { value: '950' } })
  fireEvent.click(screen.getByRole('button', { name: 'Review pending proposal' }))
  fireEvent.click(screen.getByRole('checkbox', { name: 'I reviewed this exact pending proposal and mapping choice.' }))
  fireEvent.click(screen.getByRole('button', { name: 'Save pending proposal' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Review approval for draft 300' }))
  await screen.findByText('The saved household card changed after this proposal. Re-review its current values; this stale proposal cannot be approved.')
  expect((screen.getByRole('button', { name: 'Approve reviewed card terms' }) as HTMLButtonElement).disabled).toBe(true)
})

it('statement corrections retain the explicitly linked household identity without copying household values', () => {
  const version = { ...fictionalVersion(), household_debt_id: 950, household_debt_fingerprint: fictionalHouseholdCandidate.fingerprint, household_debt_snapshot: fictionalHouseholdCandidate.snapshot }
  const card = { id: 1, savings_enrollment_id: 801, lock_version: 1, current_version_id: 10, source_tracked_account_id: null, household_debt_id: 950, current_version: version }
  const review = vi.fn()
  render(<OptionalDebtTerms localToday="2026-11-01" card={card} candidates={[{ ...fictionalCandidate, statement_as_of_on: '2026-11-01', proposed_terms: { ...fictionalCandidate.proposed_terms, as_of_on: '2026-11-01' } }]} householdCandidates={[{ ...fictionalHouseholdCandidate, linked_card_id: 1 }]} busy={false} onReview={review}/>)
  fireEvent.change(screen.getByLabelText('How will you review these terms?'), { target: { value: 'source' } })
  expect((screen.getByLabelText('Link to a saved household card (optional)') as HTMLSelectElement).value).toBe('950')
  fireEvent.change(screen.getByLabelText('Exact approved liability account'), { target: { value: '901' } })
  expect((screen.getByLabelText('Balance in US dollars') as HTMLInputElement).value).toBe('870.00')
  fireEvent.change(screen.getByLabelText('Reason for this review (required for correction)'), { target: { value: 'Reviewed the current statement' } })
  fireEvent.click(screen.getByRole('button', { name: 'Review pending proposal' }))
  expect(review).toHaveBeenCalledWith(expect.objectContaining({ terms: expect.objectContaining({ balance_cents: 87000, minimum_payment_cents: null }), source_mapping: expect.objectContaining({ source_account_identity_version_id: 901 }), household_debt_mapping: { household_debt_id: 950, fingerprint: fictionalHouseholdCandidate.fingerprint } }))
})
