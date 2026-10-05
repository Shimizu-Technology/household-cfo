// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError } from '../api'
import * as api from '../api'
import { savingsEntryDraft, savingsEntryVersion, savingsFixture, savingsPlanDraft } from '../test/savingsFixtures'
import { SavingsChallengeHome } from './SavingsChallengeHome'
vi.mock('../contexts/brandContextValue', () => ({ useBrand: () => ({ assistantName: 'Mia' }) }))
vi.mock('../api', async (original) => ({ ...await original<typeof import('../api')>(), fetchSavingsChallenge: vi.fn(), fetchSavingsPage: vi.fn(), stageSavingsPlan: vi.fn(), approveSavingsPlan: vi.fn(), stageSavingsEntry: vi.fn(), approveSavingsEntry: vi.fn(), enrollSavingsChallenge: vi.fn(), attestSavingsZero: vi.fn() }))
const fetchChallenge = vi.mocked(api.fetchSavingsChallenge)
const fetchPage = vi.mocked(api.fetchSavingsPage)
function view(key = 'first') { return <SavingsChallengeHome key={key} onAskMia={vi.fn()} onReviewStatements={vi.fn()} /> }
beforeEach(() => { vi.clearAllMocks(); fetchChallenge.mockResolvedValue(savingsFixture()); fetchPage.mockResolvedValue({ records: [], next_cursor: null }) })
afterEach(() => { cleanup(); vi.useRealTimers(); vi.restoreAllMocks() })
describe('participant savings Home', () => {
  it('does not invent zero or accepted target and requires explicit known-zero acceptance', async () => {
    render(view()); await screen.findAllByText('Not yet reported')
    expect(screen.getByText('Not yet approved')).toBeTruthy()
    expect(screen.queryByRole('progressbar')).toBeNull()
    const confirm = screen.getByRole('button', { name: 'Confirm known zero' })
    expect((confirm as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(screen.getByLabelText(/I know I have no eligible/))
    vi.mocked(api.attestSavingsZero).mockResolvedValue({ record: { id: 1, cutoff_on: '2026-10-04', approval_sequence: 1, previous_attestation_id: null, approved_at: '' }, replayed: false, challenge: savingsFixture() })
    fireEvent.click(confirm)
    await waitFor(() => expect(api.attestSavingsZero).toHaveBeenCalledWith({ known_zero: true, cutoff_on: '2026-10-04', expected_enrollment_lock_version: 0 }, expect.any(String), expect.any(AbortSignal)))
  })
  it('requires late-start acceptance and submits the authoritative policy and dates', async () => {
    fetchChallenge.mockResolvedValue(savingsFixture(false))
    render(view()); await screen.findByText(/2026-10-04 – 2027-01-01/)
    fireEvent.click(screen.getByLabelText(/read this notice/))
    expect((screen.getByRole('button', { name: 'Accept and join' }) as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(screen.getByLabelText(/later personal start/))
    vi.mocked(api.enrollSavingsChallenge).mockResolvedValue({ record: savingsFixture().enrollment!, challenge: savingsFixture(), replayed: false })
    fireEvent.click(screen.getByRole('button', { name: 'Accept and join' }))
    await waitFor(() => expect(api.enrollSavingsChallenge).toHaveBeenCalledWith({ participation_accepted: true, policy_version: 'dev-notice-v1', late_start_accepted: true, expected_acceptance_digest: 'a'.repeat(64) }, expect.any(String), expect.any(AbortSignal)))
  })
  it('stages custom exact target as a proposal and preserves unapproved progress', async () => {
    vi.mocked(api.stageSavingsPlan).mockResolvedValue({ record: savingsPlanDraft(12550), challenge: { ...savingsFixture(), pending_plan_count: 1 }, replayed: false })
    render(view()); await screen.findByText('Not yet approved')
    fireEvent.change(screen.getByLabelText('Target in US dollars'), { target: { value: '125.50' } })
    fireEvent.click(screen.getByRole('button', { name: 'Review target plan' }))
    await waitFor(() => expect(api.stageSavingsPlan).toHaveBeenCalledWith({ target_cents: 12550, expected_plan_version_id: null, reason: '' }, expect.any(String), expect.any(AbortSignal)))
    expect(screen.getByText('Not yet approved')).toBeTruthy()
  })
  it('retries an uncertain request with identical key and payload while pausing edits and refresh', async () => {
    vi.mocked(api.stageSavingsEntry).mockRejectedValueOnce(new Error('Connection interrupted')).mockResolvedValueOnce({ record: savingsEntryDraft(), challenge: savingsFixture(), replayed: true })
    render(view()); await screen.findByText('Not yet approved')
    fireEvent.change(screen.getByLabelText('Amount in US dollars'), { target: { value: '25.50' } })
    fireEvent.click(screen.getByRole('button', { name: 'Review savings record' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Retry same request' }))
    await screen.findByText(/earlier request was confirmed/)
    const calls = vi.mocked(api.stageSavingsEntry).mock.calls
    expect(calls).toHaveLength(2); expect(calls[1].slice(0, 2)).toEqual(calls[0].slice(0, 2))
  })
  it('stages corrections using current version/entry locks without changing approved totals', async () => {
    const fixture = savingsFixture(); fixture.projection = { ...fixture.projection!, reporting_known: true, reported_cents: 2550, evidence_supported_cents: 0 }
    fetchChallenge.mockResolvedValue(fixture)
    const entry = { id: 41, current_approved_version_id: 51, lock_version: 2, current_approved_version: savingsEntryVersion() }
    fetchPage.mockImplementation(async (collection) => ({ records: collection === 'entries' ? [entry] : [], next_cursor: null }))
    vi.mocked(api.stageSavingsEntry).mockResolvedValue({ record: savingsEntryDraft(1000), challenge: fixture, replayed: false })
    HTMLElement.prototype.scrollIntoView = vi.fn()
    render(view()); fireEvent.click(await screen.findByRole('button', { name: 'Correct record #41' }))
    fireEvent.change(screen.getByLabelText('Amount in US dollars'), { target: { value: '10.00' } })
    fireEvent.change(screen.getByLabelText('Reason for correction'), { target: { value: 'Corrected amount' } })
    fireEvent.click(screen.getByRole('button', { name: 'Review savings record' }))
    await waitFor(() => expect(api.stageSavingsEntry).toHaveBeenCalledWith(expect.objectContaining({ signed_cents: 1000, entry_id: 41, expected_version_id: 51, expected_entry_lock_version: 2, reason: 'Corrected amount' }), expect.any(String), expect.any(AbortSignal)))
    expect(within(screen.getByRole('article', { name: 'Approved savings progress' })).getByText('$25.50')).toBeTruthy()
  })
  it('preserves typed entry on background refresh and clears it after revoked access', async () => {
    render(view()); await screen.findByText('Not yet approved')
    const input = screen.getByLabelText('Amount in US dollars') as HTMLInputElement
    fireEvent.change(input, { target: { value: '37.25' } })
    fireEvent(window, new Event('focus'))
    await waitFor(() => expect(fetchChallenge).toHaveBeenCalledTimes(2))
    expect(input.value).toBe('37.25')
    fetchChallenge.mockRejectedValueOnce(new ApiRequestError('Revoked', { status: 403 }))
    fireEvent(window, new Event('focus'))
    await screen.findByText('Revoked')
    expect(screen.queryByLabelText('Amount in US dollars')).toBeNull()
    expect(screen.queryByRole('article', { name: 'Approved savings progress' })).toBeNull()
  })
  it('does not render late private responses after a scope-key switch', async () => {
    let release!: (value: ReturnType<typeof savingsFixture>) => void
    fetchChallenge.mockImplementationOnce(() => new Promise((resolve) => { release = resolve })).mockResolvedValue(savingsFixture(false))
    const ui = render(view()); await waitFor(() => expect(fetchChallenge).toHaveBeenCalledTimes(1))
    const signal = fetchChallenge.mock.calls[0][0]
    ui.rerender(view('new-scope'))
    await screen.findByText('Review before joining')
    await act(async () => release(savingsFixture()))
    expect(signal?.aborted).toBe(true)
    expect(screen.queryByText('Not yet approved')).toBeNull()
  })
  it('stages postponed target as null without pretending an accepted $500 target', async () => {
    vi.mocked(api.stageSavingsPlan).mockResolvedValue({ record: { ...savingsPlanDraft(), target_cents: null }, challenge: savingsFixture(), replayed: false })
    render(view()); await screen.findByText('Not yet approved')
    fireEvent.click(screen.getByLabelText('I will choose my target later'))
    fireEvent.click(screen.getByRole('button', { name: 'Review target plan' }))
    await waitFor(() => expect(api.stageSavingsPlan).toHaveBeenCalledWith({ target_cents: null, expected_plan_version_id: null, reason: '' }, expect.any(String), expect.any(AbortSignal)))
    expect(screen.getByText('Not yet approved')).toBeTruthy()
  })
  it('requires new acceptance when an offered policy or personal window changes', async () => {
    fetchChallenge.mockResolvedValueOnce(savingsFixture(false)).mockResolvedValue({ ...savingsFixture(false), offer: { ...savingsFixture(false).offer!, policy_version: 'dev-notice-v2', personal_ends_on: '2027-01-02' } })
    render(view()); await screen.findByText('Review before joining')
    fireEvent.click(screen.getByLabelText(/read this notice/)); fireEvent.click(screen.getByLabelText(/later personal start/))
    fireEvent(window, new Event('focus'))
    await screen.findByText(/dev-notice-v2/)
    expect((screen.getByLabelText(/read this notice/) as HTMLInputElement).checked).toBe(false)
    expect((screen.getByRole('button', { name: 'Accept and join' }) as HTMLButtonElement).disabled).toBe(true)
  })
  it('rejects future actuals and fractional cents without a draft write', async () => {
    render(view()); await screen.findByText('Not yet approved')
    const form = screen.getByRole('region', { name: 'Report actual savings' }).querySelector('form')!
    fireEvent.change(screen.getByLabelText('Amount in US dollars'), { target: { value: '1.005' } })
    fireEvent.submit(form)
    await screen.findByText(/at most two decimal places/)
    fireEvent.change(screen.getByLabelText('Amount in US dollars'), { target: { value: '1.00' } })
    fireEvent.change(screen.getByLabelText('Date money was set aside or withdrawn'), { target: { value: '2026-10-05' } })
    fireEvent.submit(form)
    await screen.findByText(/Future promises/)
    expect(api.stageSavingsEntry).not.toHaveBeenCalled()
  })
  it('shows signed negative server totals with a zero bar and no zero attestation shortcut', async () => {
    const fixture = savingsFixture(); fixture.projection = { ...fixture.projection!, reporting_known: true, reported_cents: -2550, evidence_supported_cents: 0, progress_basis_points: 0 }
    fetchChallenge.mockResolvedValue(fixture)
    render(view()); await screen.findByText('-$25.50')
    expect(screen.getByRole('progressbar').getAttribute('value')).toBe('0')
    expect(screen.queryByRole('button', { name: 'Confirm known zero' })).toBeNull()
  })
  it('preserves typed inputs on a transient background failure and disables changes until refreshed', async () => {
    render(view()); await screen.findByText('Not yet approved')
    fireEvent.change(screen.getByLabelText('Amount in US dollars'), { target: { value: '17.25' } })
    fetchChallenge.mockRejectedValueOnce(new Error('Temporary unavailable'))
    fireEvent(window, new Event('focus'))
    await screen.findByText('Temporary unavailable')
    expect((screen.getByLabelText('Amount in US dollars') as HTMLInputElement).value).toBe('17.25')
    expect((screen.getByRole('button', { name: 'Review savings record' }).closest('fieldset') as HTMLFieldSetElement).disabled).toBe(true)
    fireEvent.click(screen.getByRole('button', { name: 'Refresh challenge' }))
    await waitFor(() => expect((screen.getByRole('button', { name: 'Review savings record' }).closest('fieldset') as HTMLFieldSetElement).disabled).toBe(false))
  })

  it('preserves exact contribution input after a stale review conflict until refreshed', async () => {
    vi.mocked(api.stageSavingsEntry).mockRejectedValueOnce(new ApiRequestError('Review changed; refresh first', { status: 409 }))
    render(view()); await screen.findByText('Not yet approved')
    fireEvent.change(screen.getByLabelText('Amount in US dollars'), { target: { value: '27.35' } })
    fireEvent.click(screen.getByRole('button', { name: 'Review savings record' }))
    await screen.findByText('Review changed; refresh first')
    expect((screen.getByLabelText('Amount in US dollars') as HTMLInputElement).value).toBe('27.35')
    expect((screen.getByLabelText('Amount in US dollars').closest('fieldset') as HTMLFieldSetElement).disabled).toBe(true)
    fireEvent.click(screen.getByRole('button', { name: 'Refresh challenge' }))
    await waitFor(() => expect((screen.getByLabelText('Amount in US dollars').closest('fieldset') as HTMLFieldSetElement).disabled).toBe(false))
    expect((screen.getByLabelText('Amount in US dollars') as HTMLInputElement).value).toBe('27.35')
  })

})

it('offers evidence review only for current positive eligible entries and displays returned quality honestly',async()=>{const review=vi.fn();fetchPage.mockImplementation(async collection=>({records:collection==='entries'?[{id:41,lock_version:1,current_approved_version_id:51,current_approved_version:{...savingsEntryVersion(),evidence_status:'stale',evidence_supported_cents:0}},{id:42,lock_version:1,current_approved_version_id:52,current_approved_version:{...savingsEntryVersion(),id:52,funding_source:'borrowed'}},{id:43,lock_version:1,current_approved_version_id:53,current_approved_version:{...savingsEntryVersion(),id:53,signed_cents:-500,funding_source:'withdrawal'}}]:[],next_cursor:null}));render(<SavingsChallengeHome onAskMia={vi.fn()} onReviewStatements={vi.fn()} onReviewEvidence={review}/>);await screen.findByText(/Linked proof needs review/);expect(screen.getAllByRole('button',{name:'Review savings evidence'})).toHaveLength(1);fireEvent.click(screen.getByRole('button',{name:'Review savings evidence'}));expect(review).toHaveBeenCalledWith(51);expect(screen.getAllByText(/Supported subset:.*part of the reported amount/)).toHaveLength(3)})
it('pages approved entry revisions and opens optional proof review for an old eligible contribution without editing totals',async()=>{const reviewed=vi.fn();const old={...savingsEntryVersion(5000),id:11,reason:'Earlier approved contribution'};fetchPage.mockImplementation(async(collection,cursor)=>({records:collection==='entry_versions'?(cursor?[old]:[{...old,id:8,funding_source:'borrowed'}]):[],next_cursor:collection==='entry_versions'&&!cursor?8:null}));render(<SavingsChallengeHome onAskMia={vi.fn()} onReviewStatements={vi.fn()} onReviewEvidence={reviewed}/>);await screen.findByText('Not yet approved');fireEvent.click(screen.getByText('Savings entry revision history',{exact:true}));const history=screen.getByRole('region',{name:'Savings entry revisions'});await within(history).findByText(/Borrowed money/);expect(within(history).queryByRole('button',{name:/Review proof for/})).toBeNull();fireEvent.click(within(history).getByRole('button',{name:'Next records'}));fireEvent.click(await within(history).findByRole('button',{name:'Review proof for savings revision 1'}));expect(reviewed).toHaveBeenCalledWith(11);expect(screen.getByRole('article',{name:'Approved savings progress'}).textContent).toContain('Not yet reported');expect(api.stageSavingsEntry).not.toHaveBeenCalled()})
