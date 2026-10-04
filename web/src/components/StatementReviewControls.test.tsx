// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError, fetchStatementReviewRequestStatus, fetchSourceDuplicateCandidates, fetchTrackedSourceAccounts, mutateStatementReview } from '../api'
import { sourceReviewFixture } from '../../e2e/sourceReviewFixtures'
import type { ParticipantSourceReview } from '../lib/participantSourceReview'
import { statementCents } from '../lib/participantSourceReview'
import { useStatementReviewMutation } from '../lib/useStatementReviewMutation'
import { StatementEconomicReview } from './StatementEconomicReview'
import { StatementBatchReview } from './StatementBatchReview'
import { bindStatementReviewActor, clearStatementReviewRecovery, readStatementReviewRecovery, setStatementReviewExpectedUser } from '../lib/statementReviewRecovery'
import { StatementAccountReview, StatementCoverageReview, StatementRowEditor } from './StatementReviewControls'
vi.mock('../api', async (original) => ({ ...await original<typeof import('../api')>(), fetchTrackedSourceAccounts: vi.fn(), fetchSourceDuplicateCandidates: vi.fn(), mutateStatementReview: vi.fn(), fetchStatementReviewRequestStatus: vi.fn() }))
const fixture = sourceReviewFixture()
const event = { ...fixture.events[3], event_type: 'purchase' as const, signed_amount_cents: -1_000, expense_amount_cents: 1_000, posted_on: '2026-07-07' }
function context(): ParticipantSourceReview {
  return { schema_version: 1, actor_scope: { user_id: 1, household_id: 77 }, categories: [{ id: 10, name: 'Groceries' }], rows: { [event.id]: { head: { id: 50, approved_version_id: null, lock_version: 0 }, approved: null, pending: null } },
    accounts: [{ source_account_id: event.financial_source_account_id, head: { id: 80, approved_version_id: 100, lock_version: 1 }, approved: { id: 100, digest: 'account-digest', version_number: 1,
      tracked_account: { id: 2, label: 'My checking', account_basis: 'asset', account_id: null }, statement_facts: { period_start_on: '2026-07-01', period_end_on: '2026-07-31', opening_balance_cents: 1_000, closing_balance_cents: 0, printed_debit_cents: 1_000, printed_credit_cents: 0, printed_row_count: 1 } } }],
    coverage: { revision_id: 88, represented_rows: 137, approved_rows: 10, pending_corrections: 1, content_digest: 'coverage-digest', deficiencies: ['unreviewed_source_rows'] }, approved_coverage: null }
}
afterEach(cleanup)
beforeEach(() => {
  setStatementReviewExpectedUser(1); bindStatementReviewActor({ user_id: 1, household_id: 77 }); const pending = readStatementReviewRecovery({ user_id: 1, household_id: 77 }); if (pending) clearStatementReviewRecovery(pending.key)
  vi.mocked(fetchStatementReviewRequestStatus).mockReset().mockResolvedValue({ state: 'committed', record: {}, replayed: true })
  vi.mocked(fetchTrackedSourceAccounts).mockReset().mockResolvedValue({ records: [{ id: 2, label: 'My checking', account_basis: 'asset', account_id: null }], next_cursor: null })
  vi.mocked(fetchSourceDuplicateCandidates).mockReset().mockResolvedValue({ records: [], next_cursor: null })
  vi.mocked(mutateStatementReview).mockReset()
})
describe('participant source approval controls', () => {
  it('parses exact signed cents and keeps blank unknown distinct from zero', () => {
    expect(statementCents('')).toBeNull(); expect(statementCents('0')).toBe(0)
    expect(statementCents('-0.01')).toBe(-1); expect(statementCents('499.99')).toBe(49_999)
    for (const value of ['1.005', '1e2', 'NaN', '1,000.00', '1 00']) expect(() => statementCents(value)).toThrow()
  })
  it('requires reviewed account identity before proposing a row', () => {
    const data = context(); data.accounts[0].approved = null
    render(<StatementRowEditor importId={1203} context={data} event={event} mutate={vi.fn()} disabled={false} />)
    expect(screen.getByText(/Review this row’s account details first/)).toBeTruthy()
    expect(screen.queryByRole('button', { name: 'Save proposal for review' })).toBeNull()
  })
  it('stages exact reviewed facts without publishing an actual or approving the row', async () => {
    const mutate = vi.fn().mockResolvedValue(undefined)
    render(<StatementRowEditor importId={1203} context={context()} event={event} mutate={mutate} disabled={false} />)
    fireEvent.change(screen.getByLabelText('Review note'), { target: { value: 'I checked the amount against my statement.' } })
    fireEvent.change(screen.getByLabelText('Spending category'), { target: { value: '10' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save proposal for review' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledTimes(1))
    expect(mutate).toHaveBeenCalledWith('stage', expect.objectContaining({ base_version_id: null, base_lock_version: 0, expected_pending_draft: null,
      projection: { action: 'none' }, facts: expect.objectContaining({ signed_amount_cents: -1_000, purchase_amount_cents: 1_000, source_account_identity_version_id: 100, budget_category_id: 10 }) }))
  })
  it('shows the saved proposal independently of unsaved form changes and approves its exact fingerprint', async () => {
    const data = context(); const row = data.rows[event.id]
    row.pending = { id: 900, digest: 'exact-proposal', lock_version: 3, status: 'pending', reason: 'Reviewed original proposal', projection: { action: 'none' }, facts: {
      source_account_identity_version_id: 100, disposition: 'include', event_type: 'purchase', signed_amount_cents: -900, purchase_amount_cents: 900, posted_on: '2026-07-07', merchant: 'Saved merchant', budget_category_id: 10, overlap_disposition: 'new' } }
    const mutate = vi.fn().mockResolvedValue(undefined)
    render(<StatementRowEditor importId={1203} context={data} event={event} mutate={mutate} disabled={false} />)
    fireEvent.change(screen.getByLabelText('Signed movement'), { target: { value: '-999.00' } })
    expect(screen.getByText(/Saved merchant · Complete purchase \$9.00/)).toBeTruthy()
    const approve = screen.getByRole('button', { name: 'Approve saved row proposal' })
    expect((approve as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(screen.getByRole('checkbox', { name: /I reviewed this saved proposal/ }))
    fireEvent.click(approve)
    expect(mutate).toHaveBeenCalledWith('approve', { draft_id: 900, draft_digest: 'exact-proposal', draft_lock_version: 3 })
  })
  it('makes actual creation an explicit choice and preserves correction fingerprint', async () => {
    const data = context()
    data.rows[event.id].approved = { id: 401, digest: 'row-digest', version_number: 1, reason: 'Original review', projection: { action: 'create' }, actual: { id: 77, digest: 'old-actual-digest', amount_cents: 1_000 }, facts: {
      source_account_identity_version_id: 100, disposition: 'include', event_type: 'purchase', signed_amount_cents: -1_000, purchase_amount_cents: 1_000, posted_on: '2026-07-07', merchant: 'Old merchant', budget_category_id: 10, overlap_disposition: 'new' } }
    data.rows[event.id].head.approved_version_id = 401
    const mutate = vi.fn().mockResolvedValue(undefined)
    render(<StatementRowEditor importId={1203} context={data} event={event} mutate={mutate} disabled={false} />)
    expect(screen.getByText(/Approved version 1 remains in use/)).toBeTruthy()
    fireEvent.change(screen.getByLabelText('Review note'), { target: { value: 'Corrected amount' } })
    fireEvent.click(screen.getByRole('checkbox', { name: /Replace the previous spending entry/ }))
    fireEvent.click(screen.getByRole('button', { name: 'Save proposal for review' }))
    expect(mutate).toHaveBeenCalledWith('stage', expect.objectContaining({ projection: { action: 'replace', transaction_id: 77, expected_digest: 'old-actual-digest' } }))
  })
  it('does not offer complete coverage while known deficiencies remain', () => {
    render(<StatementCoverageReview context={context()} mutate={vi.fn()} disabled={false} />)
    fireEvent.click(screen.getByText('3. Approve statement coverage and limitations'))
    expect((screen.getByRole('option', { name: 'Complete statement coverage' }) as HTMLOptionElement).disabled).toBe(true)
    expect(screen.getByText(/10 \/ 137 rows approved/)).toBeTruthy()
    expect((screen.getByRole('button', { name: 'Approve declared coverage' }) as HTMLButtonElement).disabled).toBe(true)
  })
  it('loads canonical accounts and requires an explicit checked header before approval', async () => {
    const data = context(); const sourceAccount = { ...fixture.accounts[0], id: event.financial_source_account_id }
    const mutate = vi.fn().mockResolvedValue(undefined)
    render(<StatementAccountReview context={data} accounts={[sourceAccount]} mutate={mutate} disabled={false} />)
    fireEvent.click(screen.getByRole('button', { name: 'Correct account details' }))
    await screen.findByRole('option', { name: /My checking · bank/ })
    fireEvent.change(screen.getByLabelText('Review note'), { target: { value: 'Checked July header' } })
    const button = screen.getByRole('button', { name: 'Approve these account details' })
    expect((button as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(screen.getByRole('checkbox', { name: /I checked the account, period/ }))
    fireEvent.click(button)
    await waitFor(() => expect(mutate).toHaveBeenCalledWith('account_link', expect.objectContaining({ tracked_account_id: 2, base_version_id: 100, base_lock_version: 1,
      statement_facts: expect.objectContaining({ printed_credit_cents: 0, closing_balance_cents: 0 }) })))
  })
})
function MutationHarness({ refresh }: { refresh: () => void }) {
  const state = useStatementReviewMutation({ importId: 1203, revisionId: 88, scope: { user_id: 1, household_id: 77 }, refresh })
  return <><button disabled={state.busy} onClick={() => { void state.mutate('approve', { draft_id: 900, draft_digest: 'frozen', draft_lock_version: 1 }) }}>Approve</button>{state.error && <p role="alert">{state.error}</p>}{state.retry && <button onClick={() => { void state.retry?.() }}>Retry same request</button>}{state.checkStatus && <button onClick={() => { void state.checkStatus?.() }}>Check result</button>}{state.accessDenied && <p>Private view cleared</p>}</>
}
describe('statement mutation recovery', () => {
  it('freezes identity and payload across an uncertain response and permits only the same retry', async () => {
    vi.mocked(mutateStatementReview).mockRejectedValueOnce(new Error('Connection lost')).mockResolvedValueOnce({ record: { id: 401 }, replayed: true })
    const refresh = vi.fn(); render(<MutationHarness refresh={refresh} />)
    fireEvent.click(screen.getByRole('button', { name: 'Approve' }))
    await screen.findByRole('button', { name: 'Retry same request' })
    expect((screen.getByRole('button', { name: 'Approve' }) as HTMLButtonElement).disabled).toBe(true)
    const first = vi.mocked(mutateStatementReview).mock.calls[0]
    fireEvent.click(screen.getByRole('button', { name: 'Retry same request' }))
    await waitFor(() => expect(refresh).toHaveBeenCalledTimes(1))
    const second = vi.mocked(mutateStatementReview).mock.calls[1]
    expect(second.slice(0, 5)).toEqual(first.slice(0, 5))
  })
  it('clears private review on forbidden response', async () => {
    vi.mocked(mutateStatementReview).mockRejectedValueOnce(new ApiRequestError('Access removed', { status: 403 }))
    render(<MutationHarness refresh={vi.fn()} />); fireEvent.click(screen.getByRole('button', { name: 'Approve' }))
    await screen.findByText('Private view cleared')
    expect(screen.queryByRole('button', { name: 'Retry same request' })).toBeNull()
  })
})

function approvedRow() {
  return { id: 401, digest: 'approved-digest', version_number: 1, reason: 'Checked source', projection: { action: 'none' }, actual: null, source: { document_import_id: 1203, filename: 'Fictional wallet.pdf', locator: { page: 3, row: 8 }, source_available: true }, facts: {
    source_account_identity_version_id: 100, disposition: 'include' as const, event_type: 'purchase' as const, signed_amount_cents: -1_000, purchase_amount_cents: 1_000, posted_on: '2026-07-07', authorized_on: '2026-07-06', external_reference: 'fictional-reference', merchant: 'Reviewed merchant', budget_category_id: 10, overlap_disposition: 'canonical' as const } }
}
describe('material statement review repairs', () => {
  it('retains complete purchase facts on a duplicate match and identifies its exact source', async () => {
    const canonical = approvedRow(); canonical.facts.purchase_amount_cents = 2_000
    vi.mocked(fetchSourceDuplicateCandidates).mockResolvedValue({ records: [canonical], next_cursor: null })
    const mutate = vi.fn().mockResolvedValue(true)
    render(<StatementRowEditor importId={1203} context={context()} event={event} mutate={mutate} disabled={false} />)
    fireEvent.change(screen.getByLabelText('How to use this row'), { target: { value: 'match' } })
    fireEvent.click(await screen.findByRole('radio', { name: /Reviewed merchant.*Fictional wallet.pdf.*Page 3.*row 8/ }))
    fireEvent.change(screen.getByLabelText('Review note'), { target: { value: 'Compared original physical source.' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save proposal for review' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledWith('stage', expect.objectContaining({ projection: { action: 'none' }, facts: expect.objectContaining({ disposition: 'match', matched_version_id: 401, signed_amount_cents: -1_000, purchase_amount_cents: 2_000, budget_category_id: 10 }) })))
  })
  it('keeps reviewed authorized date/reference and existing actual unchanged on a source-only correction', () => {
    const data = context(); data.rows[event.id].approved = { ...approvedRow(), actual: { id: 77, digest: 'current-spending', amount_cents: 1_000 } }
    const mutate = vi.fn().mockResolvedValue(true)
    render(<StatementRowEditor importId={1203} context={data} event={event} mutate={mutate} disabled={false} />)
    fireEvent.change(screen.getByLabelText('Merchant / description'), { target: { value: 'Correct merchant' } })
    fireEvent.change(screen.getByLabelText('Review note'), { target: { value: 'Corrected name only' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save proposal for review' }))
    expect(mutate).toHaveBeenCalledWith('stage', expect.objectContaining({ projection: { action: 'none' }, facts: expect.objectContaining({ authorized_on: '2026-07-06', external_reference: 'fictional-reference' }) }))
    expect(screen.getByText(/Existing spending of \$10.00 stays unchanged/)).toBeTruthy()
  })
  it('retries failed account pages at the same cursor without losing selected account', async () => {
    vi.mocked(fetchTrackedSourceAccounts).mockRejectedValueOnce(new Error('Choices offline')).mockResolvedValueOnce({ records: [], next_cursor: 50 }).mockRejectedValueOnce(new Error('Second page offline')).mockResolvedValueOnce({ records: [{ id: 51, label: 'Another account', account_basis: 'asset', account_id: null }], next_cursor: null })
    render(<StatementAccountReview context={context()} accounts={[{ ...fixture.accounts[0], id: event.financial_source_account_id }]} mutate={vi.fn()} disabled={false} />)
    fireEvent.click(screen.getByRole('button', { name: 'Correct account details' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Retry account choices' }))
    fireEvent.click(await screen.findByRole('button', { name: 'More account choices' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Retry account choices' }))
    await screen.findByRole('option', { name: /Another account/ })
    expect((screen.getByLabelText('Recognized account') as HTMLSelectElement).value).toBe('2')
    expect(vi.mocked(fetchTrackedSourceAccounts).mock.calls.map((call) => call[0])).toEqual([null,null,50,50])
  })
  it('looks up duplicates using corrected signed amount/date and has an explicit failed-query retry', async () => {
    vi.mocked(fetchSourceDuplicateCandidates).mockRejectedValueOnce(new Error('Offline')).mockResolvedValue({ records: [approvedRow()], next_cursor: null })
    render(<StatementRowEditor importId={1203} context={context()} event={event} mutate={vi.fn()} disabled={false} />)
    fireEvent.change(screen.getByLabelText('Signed movement'), { target: { value: '-20.00' } }); fireEvent.change(screen.getByLabelText('Posted date'), { target: { value: '2026-07-08' } })
    fireEvent.change(screen.getByLabelText('How to use this row'), { target: { value: 'match' } })
    fireEvent.click(await screen.findByRole('button', { name: 'Retry reviewed candidates' }))
    await screen.findByRole('radio')
    expect(fetchSourceDuplicateCandidates).toHaveBeenLastCalledWith(1203,event.id,null,expect.any(AbortSignal),{ signed_amount_cents: -2_000, posted_on: '2026-07-08' })
  })
  it('links explicit wallet/bank funding before separately projecting the full purchase', async () => {
    const wallet = approvedRow(); wallet.facts.signed_amount_cents = -2_159; wallet.facts.purchase_amount_cents = 100_000
    const bank = { ...approvedRow(), id: 402, facts: { ...approvedRow().facts, event_type: 'transfer' as const, signed_amount_cents: -97_841, purchase_amount_cents: null, merchant: 'Bank funding', source_account_identity_version_id: 101 }, source: { document_import_id: 1204, filename: 'Fictional bank.pdf', locator: { page: 2, row: 9 }, source_available: true } }
    vi.mocked(fetchSourceDuplicateCandidates).mockResolvedValue({ records: [bank], next_cursor: null })
    const mutate = vi.fn().mockResolvedValue(true)
    render(<StatementEconomicReview importId={1203} eventId={event.id} row={wallet} context={context()} mutate={mutate} disabled={false} />)
    fireEvent.click(screen.getByText('Create a related-movement link')); fireEvent.change(screen.getByLabelText('Link type'), { target: { value: 'purchase_funding' } }); fireEvent.click(screen.getByText('Choose another approved physical row'))
    fireEvent.click(await screen.findByRole('checkbox', { name: /Bank funding.*Fictional bank.pdf/ }))
    fireEvent.change(screen.getByLabelText('Link review note'), { target: { value: 'Compared wallet purchase and bank funding.' } }); fireEvent.click(screen.getByRole('checkbox', { name: /I checked every selected source/ })); fireEvent.click(screen.getByRole('button', { name: 'Approve reviewed link' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledWith('economic_link', expect.objectContaining({ kind: 'purchase_funding', members: [{ source_review_version_id: 401, role: 'purchase', allocation_cents: 2_159 }, { source_review_version_id: 402, role: 'funding', allocation_cents: 97_841 }] })))
    fireEvent.click(screen.getByText('Review spending effect separately'))
    expect((screen.getByRole('button', { name: 'Approve spending creation' }) as HTMLButtonElement).disabled).toBe(true)
    expect(screen.getByText(/Link the full purchase to its reviewed funding legs first/)).toBeTruthy()
  })
  it('stops a selected-row batch immediately on uncertainty without dropping unsubmitted rows', async () => {
    const data = context(); const second = { ...event, id: event.id + 1, position: event.position + 1 }; data.rows[second.id] = { head: { id: 51, approved_version_id: null, lock_version: 0 }, approved: null, pending: null }
    const mutate = vi.fn().mockResolvedValueOnce(false)
    render(<StatementBatchReview events={[event,second]} selected={[event.id,second.id]} context={data} mutate={mutate} disabled={false} onRunning={vi.fn()} />)
    fireEvent.change(screen.getByLabelText('Selected-row review note'), { target: { value: 'Checked both physical rows.' } }); fireEvent.click(screen.getByRole('checkbox')); fireEvent.click(screen.getByRole('button', { name: 'Save selected row proposals' }))
    await screen.findByText(/Stopped after 0 of 2/); expect(mutate).toHaveBeenCalledTimes(1)
  })
  it('retains an uncertain operation across unmount and stores only request identity in session metadata', async () => {
    vi.mocked(mutateStatementReview).mockRejectedValueOnce(new Error('Connection lost')).mockResolvedValueOnce({ record: {}, replayed: true })
    const first = render(<MutationHarness refresh={vi.fn()} />); fireEvent.click(screen.getByRole('button', { name: 'Approve' })); await screen.findByRole('button', { name: 'Retry same request' })
    const identity = sessionStorage.getItem('statement-review-request-identities-v1')!
    expect(identity).not.toContain('frozen'); expect(identity).not.toContain('draft_digest'); expect(identity).toContain('1203')
    first.unmount(); const refresh = vi.fn(); render(<MutationHarness refresh={refresh} />)
    expect((screen.getByRole('button', { name: 'Approve' }) as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(screen.getByRole('button', { name: 'Retry same request' })); await waitFor(() => expect(refresh).toHaveBeenCalledTimes(1))
    const calls = vi.mocked(mutateStatementReview).mock.calls; expect(calls[1].slice(0,5)).toEqual(calls[0].slice(0,5))
  })
})

describe('scoped statement request status recovery', () => {
  it('checks committed status without resubmitting the financial mutation', async () => {
    vi.mocked(mutateStatementReview).mockRejectedValueOnce(new Error('Lost response'))
    const refresh = vi.fn(); render(<MutationHarness refresh={refresh} />); fireEvent.click(screen.getByRole('button', { name: 'Approve' })); await screen.findByRole('button', { name: 'Check result' })
    fireEvent.click(screen.getByRole('button', { name: 'Check result' })); await waitFor(() => expect(refresh).toHaveBeenCalledTimes(1))
    expect(mutateStatementReview).toHaveBeenCalledTimes(1)
    expect(fetchStatementReviewRequestStatus).toHaveBeenCalledWith(1203,'approve',vi.mocked(mutateStatementReview).mock.calls[0][4])
  })
  it('keeps writes blocked when server status is in flight or unknown', async () => {
    vi.mocked(mutateStatementReview).mockRejectedValueOnce(new Error('Lost response'))
    vi.mocked(fetchStatementReviewRequestStatus).mockResolvedValueOnce({ state: 'in_flight' }).mockResolvedValueOnce({ state: 'unknown', can_retry: true })
    render(<MutationHarness refresh={vi.fn()} />); fireEvent.click(screen.getByRole('button', { name: 'Approve' })); await screen.findByRole('button', { name: 'Check result' })
    fireEvent.click(screen.getByRole('button', { name: 'Check result' })); await screen.findByText(/still processing/)
    expect((screen.getByRole('button', { name: 'Approve' }) as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(screen.getByRole('button', { name: 'Check result' })); await screen.findByText(/No committed result found/)
    expect((screen.getByRole('button', { name: 'Approve' }) as HTMLButtonElement).disabled).toBe(true)
  })
  it('clears financial payload on actor switch while preserving scoped identity for later status checks', async () => {
    vi.mocked(mutateStatementReview).mockRejectedValueOnce(new Error('Lost response'))
    const view = render(<MutationHarness refresh={vi.fn()} />); fireEvent.click(screen.getByRole('button', { name: 'Approve' })); await screen.findByRole('button', { name: 'Retry same request' }); view.unmount()
    setStatementReviewExpectedUser(2); bindStatementReviewActor({ user_id: 2, household_id: 88 })
    expect(readStatementReviewRecovery({ user_id: 1, household_id: 77 })).toBeNull()
    setStatementReviewExpectedUser(1); bindStatementReviewActor({ user_id: 1, household_id: 77 })
    const recovered = readStatementReviewRecovery({ user_id: 1, household_id: 77 })
    expect(recovered?.input).toBeUndefined(); expect(recovered?.key).toBe(vi.mocked(mutateStatementReview).mock.calls[0][4])
    render(<MutationHarness refresh={vi.fn()} />)
    expect(screen.queryByRole('button', { name: 'Retry same request' })).toBeNull(); expect((screen.getByRole('button', { name: 'Approve' }) as HTMLButtonElement).disabled).toBe(true)
  })
})


describe('final review consent and lookup regressions', () => {
  it('keeps explicit removal available after a source-only exclusion retains an actual', () => {
    const data = context(); const excluded = { ...approvedRow(), actual: { id: 77, digest: 'retained-actual', amount_cents: 1_000 }, facts: { ...approvedRow().facts, disposition: 'exclude' as const } }
    data.rows[event.id].approved = excluded
    const mutate = vi.fn().mockResolvedValue(true)
    render(<StatementRowEditor importId={1203} context={data} event={event} mutate={mutate} disabled={false} />)
    expect(screen.queryByText('Create a related-movement link')).toBeNull()
    fireEvent.click(screen.getByText('Review spending effect separately'))
    fireEvent.change(screen.getByLabelText('Spending review note'), { target: { value: 'Remove old spending after checking excluded source.' } })
    fireEvent.click(screen.getByRole('checkbox', { name: /I approve this exact spending effect/ }))
    fireEvent.click(screen.getByRole('button', { name: 'Approve spending removal' }))
    expect(mutate).toHaveBeenCalledWith('project', { version_id: 401, expected_version_digest: 'approved-digest', projection: { action: 'void', transaction_id: 77, expected_digest: 'retained-actual' }, reason: 'Remove old spending after checking excluded source.' })
  })
  it('restarts duplicate pagination when corrected facts change', async () => {
    vi.mocked(fetchSourceDuplicateCandidates).mockResolvedValue({ records: [approvedRow()], next_cursor: 401 })
    render(<StatementRowEditor importId={1203} context={context()} event={event} mutate={vi.fn()} disabled={false} />)
    fireEvent.change(screen.getByLabelText('How to use this row'), { target: { value: 'match' } })
    fireEvent.click(await screen.findByRole('button', { name: 'More reviewed candidates' }))
    await waitFor(() => expect(fetchSourceDuplicateCandidates).toHaveBeenLastCalledWith(1203,event.id,401,expect.any(AbortSignal),{ signed_amount_cents: -1_000, posted_on: '2026-07-07' }))
    fireEvent.change(screen.getByLabelText('Signed movement'), { target: { value: '-20.00' } })
    await waitFor(() => expect(fetchSourceDuplicateCandidates).toHaveBeenLastCalledWith(1203,event.id,null,expect.any(AbortSignal),{ signed_amount_cents: -2_000, posted_on: '2026-07-07' }))
  })
  it('rejects binding an old private actor after sign out', () => {
    setStatementReviewExpectedUser(null)
    expect(bindStatementReviewActor({ user_id: 1, household_id: 77 })).toBe(false)
  })
})
