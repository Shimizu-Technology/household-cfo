// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError } from '../api'
import * as api from '../api'
import { savingsEntryDraft, savingsEntryVersion, savingsFixture, savingsPlanDraft, savingsPlanVersion } from '../test/savingsFixtures'
import { SavingsChallengeHome } from './SavingsChallengeHome'
vi.mock('../contexts/brandContextValue', () => ({ useBrand: () => ({ assistantName: 'Mia' }) }))
vi.mock('../api', async (original) => ({ ...await original<typeof import('../api')>(), fetchSavingsChallenge: vi.fn(), fetchSavingsPage: vi.fn(), stageSavingsPlan: vi.fn(), approveSavingsPlan: vi.fn(), stageSavingsEntry: vi.fn(), approveSavingsEntry: vi.fn(), enrollSavingsChallenge: vi.fn(), attestSavingsZero: vi.fn() }))
const fetchChallenge = vi.mocked(api.fetchSavingsChallenge)
const fetchPage = vi.mocked(api.fetchSavingsPage)
function view(key = 'first') { return <SavingsChallengeHome key={key} onAskMia={vi.fn()} onReviewStatements={vi.fn()} /> }
beforeEach(() => { vi.clearAllMocks(); fetchChallenge.mockResolvedValue(savingsFixture()); fetchPage.mockResolvedValue({ records: [], next_cursor: null }) })
afterEach(() => { cleanup(); vi.useRealTimers(); vi.restoreAllMocks() })
describe('participant savings Home', () => {
  it('lists the privacy entry with the other plain rows, named like the account menu', async () => {
    render(<SavingsChallengeHome onAskMia={vi.fn()} onReviewStatements={vi.fn()} privacyAccess={<button type="button">Privacy &amp; reminders</button>} />)
    await screen.findByText('No amounts added yet')
    const rows = document.querySelector('.savings-rows') as HTMLElement
    expect(within(rows).getByRole('button', { name: 'Privacy & reminders' })).toBeTruthy()
    expect(within(rows).getByText('Your target & spending choices')).toBeTruthy()
    expect(within(rows).getByText('Your records & corrections')).toBeTruthy()
    expect(within(rows).getByText('Statements & spending snapshot (optional)')).toBeTruthy()
  })

  it('answers one question first: one filled action, plain dates and no zero-count noise', async () => {
    const checkIn = vi.fn(), today = vi.fn()
    render(<SavingsChallengeHome onAskMia={vi.fn()} onReviewStatements={vi.fn()} onToday={today} onCheckIn={checkIn} />)
    const summary = await screen.findByRole('article', { name: 'Approved savings progress' })
    expect(summary.textContent).toContain('Day 4 of 90 · next check-in Day 30 on Fri, Oct 30')
    expect(summary.querySelectorAll('.savings-primary')).toHaveLength(1)
    fireEvent.click(within(summary).getByRole('button', { name: 'Check in for today' }))
    expect(checkIn).toHaveBeenCalledTimes(1); expect(today).not.toHaveBeenCalled()
    const calendar = screen.getByRole('region', { name: 'Personal challenge calendar' })
    expect(calendar.textContent).toContain('Day 30Fri, Oct 30')
    expect(calendar.querySelector('[aria-current="step"]')?.textContent).toContain('Day 30')
    const page = document.body.textContent!
    for (const noise of ['2026-10-30', 'Pacific/Guam', '0 waiting', 'not counted', 'Backed by statements']) expect(page).not.toContain(noise)
    expect(page).toContain('Dates follow Guam time.')
  })

  it('falls back to the Today form for the check-in until a chat check-in is wired', async () => {
    const today = vi.fn()
    render(<SavingsChallengeHome onAskMia={vi.fn()} onReviewStatements={vi.fn()} onToday={today} />)
    fireEvent.click(await screen.findByRole('button', { name: 'Check in for today' }))
    expect(today).toHaveBeenCalledTimes(1)
  })

  it('shows a known total with its target, matched part and uncounted records in words', async () => {
    const fixture = savingsFixture(); fixture.accepted_plan = { ...savingsPlanVersion(40000), financial_baseline_version_id: null, baseline_digest: null, spending_changes: [] }
    fixture.projection = { ...fixture.projection!, reporting_known: true, reported_cents: 7500, evidence_supported_cents: 2550, progress_basis_points: 1875, excluded_entry_count: 1 }
    fixture.pending_entry_count = 2
    fetchChallenge.mockResolvedValue(fixture)
    render(view())
    const summary = await screen.findByRole('article', { name: 'Approved savings progress' })
    expect(summary.querySelector('.savings-total')?.textContent).toBe('$75.00')
    expect(summary.textContent).toContain('of $400.00 target · 18%')
    expect(summary.textContent).toContain('$25.50 of this is matched to a statement. That’s included above, not extra.')
    expect(summary.textContent).toContain('1 record isn’t counted because it wasn’t new money')
    expect(within(summary).getByRole('button', { name: 'I set money aside · 2 to confirm' })).toBeTruthy()
    expect(screen.getByRole('progressbar').getAttribute('value')).toBe('1875')
  })

  it('does not invent zero or accepted target and requires explicit known-zero acceptance', async () => {
    render(view()); await screen.findAllByText('No amounts added yet')
    expect(screen.getByText('No target yet')).toBeTruthy()
    expect(screen.getByText(/We don’t assume \$0/)).toBeTruthy()
    expect(screen.queryByRole('progressbar')).toBeNull()
    const confirm = screen.getByRole('button', { name: 'Confirm nothing set aside' })
    expect((confirm as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(screen.getByLabelText(/I know I haven’t set aside/))
    vi.mocked(api.attestSavingsZero).mockResolvedValue({ record: { id: 1, cutoff_on: '2026-10-04', approval_sequence: 1, previous_attestation_id: null, approved_at: '' }, replayed: false, challenge: savingsFixture() })
    fireEvent.click(confirm)
    await waitFor(() => expect(api.attestSavingsZero).toHaveBeenCalledWith({ known_zero: true, cutoff_on: '2026-10-04', expected_enrollment_lock_version: 0 }, expect.any(String), expect.any(AbortSignal)))
    expect(await screen.findByText('You confirmed nothing set aside through Sun, Oct 4.')).toBeTruthy()
  })
  it('requires late-start acceptance and submits the authoritative policy and dates', async () => {
    fetchChallenge.mockResolvedValue(savingsFixture(false))
    render(view()); await waitFor(() => expect(document.querySelector('.savings-join-dates strong')?.textContent).toBe('Your 90 days: Sun, Oct 4 – Fri, Jan 1, 2027'))
    expect(document.body.textContent).not.toContain('Pacific/Guam')
    fireEvent.click(screen.getByLabelText(/accept joining the challenge/))
    expect((screen.getByRole('button', { name: 'Accept and join' }) as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(screen.getByLabelText(/start later than the group/))
    vi.mocked(api.enrollSavingsChallenge).mockResolvedValue({ record: savingsFixture().enrollment!, challenge: savingsFixture(), replayed: false })
    fireEvent.click(screen.getByRole('button', { name: 'Accept and join' }))
    await waitFor(() => expect(api.enrollSavingsChallenge).toHaveBeenCalledWith({ participation_accepted: true, policy_version: 'dev-notice-v1', late_start_accepted: true, expected_acceptance_digest: 'a'.repeat(64) }, expect.any(String), expect.any(AbortSignal)))
  })
  it('stages custom exact target as a proposal and preserves unapproved progress', async () => {
    vi.mocked(api.stageSavingsPlan).mockResolvedValue({ record: savingsPlanDraft(12550), challenge: { ...savingsFixture(), pending_plan_count: 1 }, replayed: false })
    render(view()); await screen.findByText('No target yet')
    fireEvent.change(screen.getByLabelText('Target in US dollars'), { target: { value: '125.50' } })
    fireEvent.click(screen.getByRole('button', { name: 'Review target plan' }))
    await waitFor(() => expect(api.stageSavingsPlan).toHaveBeenCalledWith({ target_cents: 12550, expected_plan_version_id: null, reason: '' }, expect.any(String), expect.any(AbortSignal)))
    // Still not an accepted target: the summary says it is waiting, never "of $125.50 target".
    expect(await screen.findByText('Target waiting for you to confirm')).toBeTruthy()
    expect(screen.getByRole('article', { name: 'Approved savings progress' }).textContent).not.toContain('$125.50')
  })
  it('retries an uncertain request with identical key and payload while pausing edits and refresh', async () => {
    vi.mocked(api.stageSavingsEntry).mockRejectedValueOnce(new Error('Connection interrupted')).mockResolvedValueOnce({ record: savingsEntryDraft(), challenge: savingsFixture(), replayed: true })
    render(view()); await screen.findByText('No target yet')
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
    render(view()); fireEvent.click(await screen.findByRole('button', { name: 'Fix the $25.50 set aside on Sun, Oct 4' }))
    fireEvent.change(screen.getByLabelText('Amount in US dollars'), { target: { value: '10.00' } })
    fireEvent.change(screen.getByLabelText('Reason for correction'), { target: { value: 'Corrected amount' } })
    fireEvent.click(screen.getByRole('button', { name: 'Review savings record' }))
    await waitFor(() => expect(api.stageSavingsEntry).toHaveBeenCalledWith(expect.objectContaining({ signed_cents: 1000, entry_id: 41, expected_version_id: 51, expected_entry_lock_version: 2, reason: 'Corrected amount' }), expect.any(String), expect.any(AbortSignal)))
    expect(within(screen.getByRole('article', { name: 'Approved savings progress' })).getByText('$25.50')).toBeTruthy()
  })
  it('preserves typed entry on background refresh and clears it after revoked access', async () => {
    render(view()); await screen.findByText('No target yet')
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
    await screen.findByText('Join the 90-day savings challenge')
    await act(async () => release(savingsFixture()))
    expect(signal?.aborted).toBe(true)
    expect(screen.queryByText('No target yet')).toBeNull()
  })
  it('offers the waiting target instead of preparing a second draft (rehearsal R-5.3)', async () => {
    let finish!: (value: Awaited<ReturnType<typeof api.stageSavingsPlan>>) => void
    vi.mocked(api.stageSavingsPlan).mockImplementation(() => new Promise((resolve) => { finish = resolve }))
    fetchPage.mockImplementation(async (collection) => ({ records: collection === 'plan_drafts' ? [savingsPlanDraft(40000)] : [], next_cursor: null }))
    render(view()); await screen.findByText('No target yet')
    fireEvent.change(screen.getByLabelText('Target in US dollars'), { target: { value: '400.00' } })
    const review = screen.getByRole('button', { name: 'Review target plan' })
    fireEvent.click(review); fireEvent.click(review)
    expect(api.stageSavingsPlan).toHaveBeenCalledTimes(1)
    await act(async () => finish({ record: savingsPlanDraft(40000), challenge: { ...savingsFixture(), pending_plan_count: 1 }, replayed: false }))
    expect(screen.queryByRole('button', { name: 'Review target plan' })).toBeNull()
    expect(screen.getByText('Your target & spending choices').closest('summary')!.textContent).toContain('1 to review')
    expect(screen.getByText('Target waiting for you to confirm')).toBeTruthy()
    // The focused submit button unmounted; focus moves to the waiting target's Confirm button, not the page.
    const confirm = await screen.findByRole('button', { name: 'Confirm $400.00 target' })
    await waitFor(() => expect(document.activeElement).toBe(confirm), { timeout: 3000 })
    fireEvent.click(screen.getByRole('button', { name: 'Change it instead' }))
    expect(screen.getByRole('button', { name: 'Review target plan' })).toBeTruthy()
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('heading', { name: 'Choose your target' })), { timeout: 3000 })
    fireEvent.click(screen.getByRole('button', { name: 'Keep the target waiting below' }))
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Confirm $400.00 target' })), { timeout: 3000 })
    // Replacing on purpose prepares one new draft, then the form closes again (changingPlan resets on this path too).
    fireEvent.click(screen.getByRole('button', { name: 'Change it instead' }))
    vi.mocked(api.stageSavingsPlan).mockResolvedValueOnce({ record: { ...savingsPlanDraft(30000), id: 12 }, challenge: { ...savingsFixture(), pending_plan_count: 1 }, replayed: false })
    fireEvent.change(screen.getByLabelText('Target in US dollars'), { target: { value: '300.00' } })
    fireEvent.click(screen.getByRole('button', { name: 'Review target plan' }))
    await waitFor(() => expect(screen.queryByRole('button', { name: 'Review target plan' })).toBeNull())
    expect(api.stageSavingsPlan).toHaveBeenCalledTimes(2)
  })
  it('fetches waiting entries directly and lists confirmed entries newest first, one request each', async () => {
    const fixture = savingsFixture(); fixture.pending_entry_count = 1; fetchChallenge.mockResolvedValue(fixture)
    const saved = (id: number) => ({ ...savingsEntryDraft(), id, status: 'approved' })
    // The waiting entry (#3) is older than every entry on the latest confirmed page.
    fetchPage.mockImplementation(async (collection, cursor, _signal, options) => collection !== 'entry_drafts' ? { records: [], next_cursor: null }
      : options?.status === 'pending' ? { records: [{ ...savingsEntryDraft(), id: 3 }], next_cursor: null }
      : cursor === null ? { records: Array.from({ length: 10 }, (_, index) => saved(14 - index)), next_cursor: 5 } : { records: [saved(4)], next_cursor: null })
    render(view())
    fireEvent.click(await screen.findByRole('button', { name: 'I set money aside · 1 to confirm' }))
    const waiting = await screen.findByRole('region', { name: 'Waiting for you to confirm' })
    expect(await within(waiting).findByRole('button', { name: 'Confirm $25.50 set aside on Sun, Oct 4' })).toBeTruthy()
    const entries = await screen.findByRole('region', { name: 'Your entries' })
    await waitFor(() => expect(within(entries).getAllByRole('listitem')).toHaveLength(10))
    expect(within(entries).getAllByRole('listitem')[0].textContent).toContain('Saved')
    expect(within(entries).queryByRole('button', { name: /^Confirm \$/ })).toBeNull()
    expect(within(entries).getByText('More records are available. Use Older records to see them.')).toBeTruthy()
    const draftCalls = fetchPage.mock.calls.filter(([collection]) => collection === 'entry_drafts')
    expect(draftCalls).toEqual([['entry_drafts', null, expect.any(AbortSignal), { direction: 'newest', status: 'pending' }], ['entry_drafts', null, expect.any(AbortSignal), { direction: 'newest', status: 'approved' }]])
    fireEvent.click(within(entries).getByRole('button', { name: 'Older records' }))
    await waitFor(() => expect(fetchPage).toHaveBeenCalledWith('entry_drafts', 5, expect.any(AbortSignal), { direction: 'newest', status: 'approved' }))
    expect(await within(entries).findByRole('button', { name: 'Newer records' })).toBeTruthy()
  })
  it('shows a staged entry at the top without an anchor, and hides the waiting list once it is confirmed', async () => {
    let waiting = [] as ReturnType<typeof savingsEntryDraft>[]
    let fixture = savingsFixture()
    fetchChallenge.mockImplementation(async () => fixture)
    fetchPage.mockImplementation(async (collection, _cursor, _signal, options) => ({ records: collection === 'entry_drafts' && options?.status === 'pending' ? waiting : [], next_cursor: null }))
    vi.mocked(api.stageSavingsEntry).mockImplementation(async () => { waiting = [savingsEntryDraft()]; fixture = { ...savingsFixture(), pending_entry_count: 1 }; return { record: savingsEntryDraft(), challenge: fixture, replayed: false } })
    vi.mocked(api.approveSavingsEntry).mockImplementation(async () => { waiting = []; fixture = { ...savingsFixture(), pending_entry_count: 0 }; return { record: savingsEntryVersion(), challenge: fixture, replayed: false } })
    render(view())
    fireEvent.click(await screen.findByRole('button', { name: 'I set money aside' }))
    fireEvent.change(screen.getByLabelText('Amount in US dollars'), { target: { value: '25.50' } })
    fireEvent.click(screen.getByRole('button', { name: 'Review savings record' }))
    const list = await screen.findByRole('region', { name: 'Waiting for you to confirm' })
    const confirm = await within(list).findByRole('button', { name: 'Confirm $25.50 set aside on Sun, Oct 4' })
    expect(within(list).queryByRole('button', { name: 'Newer records' })).toBeNull()
    expect(within(list).queryByText(/Opened at the record/)).toBeNull()
    expect(fetchPage).not.toHaveBeenCalledWith('entry_drafts', 32, expect.anything(), expect.anything())
    fireEvent.click(confirm)
    await waitFor(() => expect(screen.queryByRole('region', { name: 'Waiting for you to confirm' })).toBeNull())
    expect(screen.getByRole('region', { name: 'Add money you set aside' }).textContent).not.toContain('Nothing here yet.')
  })
  it('pages Older then Newer back to exactly the same newest page', async () => {
    const rows = Array.from({ length: 25 }, (_, index) => ({ ...savingsEntryDraft((index + 1) * 100), id: index + 1, status: 'approved' }))
    fetchPage.mockImplementation(async (collection, cursor, _signal, options) => {
      if (collection !== 'entry_drafts') return { records: [], next_cursor: null }
      const newestFirst = options?.direction === 'newest'
      const ordered = newestFirst ? [...rows].reverse().filter((row) => cursor == null || row.id < cursor) : rows.filter((row) => row.id > (cursor ?? 0))
      const records = ordered.slice(0, 10)
      return { records, next_cursor: ordered.length > 10 ? records.at(-1)!.id : null }
    })
    render(view())
    fireEvent.click(await screen.findByRole('button', { name: 'I set money aside' }))
    const entries = await screen.findByRole('region', { name: 'Your entries' })
    const shown = () => within(entries).getAllByRole('listitem').map((item) => item.textContent)
    await waitFor(() => expect(within(entries).getAllByRole('listitem')).toHaveLength(10))
    const first = shown()
    expect(within(entries).queryByRole('button', { name: 'Newer records' })?.hasAttribute('disabled') ?? true).toBe(true)
    fireEvent.click(within(entries).getByRole('button', { name: 'Older records' }))
    await waitFor(() => expect(fetchPage).toHaveBeenCalledWith('entry_drafts', 16, expect.any(AbortSignal), { direction: 'newest', status: 'approved' }))
    await waitFor(() => expect(shown()).not.toEqual(first))
    fireEvent.click(within(entries).getByRole('button', { name: 'Newer records' }))
    await waitFor(() => expect(fetchPage).toHaveBeenCalledWith('entry_drafts', 15, expect.any(AbortSignal), { direction: 'oldest', status: 'approved' }))
    await waitFor(() => expect(shown()).toEqual(first))
    expect((within(entries).getByRole('button', { name: 'Newer records' }) as HTMLButtonElement).disabled).toBe(true)
    expect((within(entries).getByRole('button', { name: 'Older records' }) as HTMLButtonElement).disabled).toBe(false)
  })
  it('makes one request for the newest confirmed entries when nothing is waiting', async () => {
    const saved = (id: number) => ({ ...savingsEntryDraft(), id, status: 'approved' })
    fetchPage.mockImplementation(async (collection) => collection !== 'entry_drafts' ? { records: [], next_cursor: null } : { records: [saved(11), saved(10)], next_cursor: null })
    render(view())
    fireEvent.click(await screen.findByRole('button', { name: 'I set money aside' }))
    const entries = await screen.findByRole('region', { name: 'Your entries' })
    await waitFor(() => expect(within(entries).getAllByRole('listitem')).toHaveLength(2))
    expect(screen.queryByRole('region', { name: 'Waiting for you to confirm' })).toBeNull()
    expect(fetchPage.mock.calls.filter(([collection]) => collection === 'entry_drafts')).toEqual([['entry_drafts', null, expect.any(AbortSignal), { direction: 'newest', status: 'approved' }]])
  })
  it('shows a confirmed zero as $0.00 with its date, and links straight to it from the unknown caption', async () => {
    render(view())
    fireEvent.click(await screen.findByRole('button', { name: 'tell us if you set nothing aside' }))
    expect(screen.getByRole('button', { name: 'I set money aside' }).getAttribute('aria-expanded')).toBe('true')
    const zero = screen.getByText('Nothing to add?')
    expect((zero.closest('details') as HTMLDetailsElement).open).toBe(true)
    await waitFor(() => expect(document.activeElement).toBe(zero), { timeout: 3000 })
    cleanup()
    const fixture = savingsFixture(); fixture.projection = { ...fixture.projection!, reporting_known: true, zero_attested: true, reported_cents: 0, evidence_supported_cents: 0, zero_attestation_id: 3 }
    fetchChallenge.mockResolvedValue(fixture)
    render(view())
    const summary = await screen.findByRole('article', { name: 'Approved savings progress' })
    await waitFor(() => expect(summary.querySelector('.savings-total')?.textContent).toBe('$0.00'))
    expect(summary.textContent).toContain('You confirmed nothing set aside through Sun, Oct 4.')
    expect(summary.textContent).not.toContain('No amounts added yet')
  })
  it('does not offer the daily check-in as the main action outside the open 90 days', async () => {
    for (const phase of ['upcoming', 'window_ended'] as const) {
      const fixture = savingsFixture(); fixture.calendar = { ...fixture.calendar!, phase, day: null }
      fetchChallenge.mockResolvedValue(fixture)
      render(<SavingsChallengeHome onAskMia={vi.fn()} onReviewStatements={vi.fn()} onToday={vi.fn()} />)
      const summary = await screen.findByRole('article', { name: 'Approved savings progress' })
      expect(within(summary).queryByRole('button', { name: 'Check in for today' })).toBeNull()
      expect(summary.querySelector('.savings-primary')).toBeNull()
      expect(summary.textContent).toContain(phase === 'upcoming' ? 'Your 90 days start Thu, Oct 1' : 'Your 90 days ended Tue, Dec 29')
      cleanup()
    }
  })
  it('stages postponed target as null without pretending an accepted $500 target', async () => {
    vi.mocked(api.stageSavingsPlan).mockResolvedValue({ record: { ...savingsPlanDraft(), target_cents: null }, challenge: savingsFixture(), replayed: false })
    render(view()); await screen.findByText('No target yet')
    fireEvent.click(screen.getByLabelText('I will choose my target later'))
    fireEvent.click(screen.getByRole('button', { name: 'Review target plan' }))
    await waitFor(() => expect(api.stageSavingsPlan).toHaveBeenCalledWith({ target_cents: null, expected_plan_version_id: null, reason: '' }, expect.any(String), expect.any(AbortSignal)))
    expect(screen.getByText('No target yet')).toBeTruthy()
  })
  it('requires new acceptance when an offered policy or personal window changes', async () => {
    fetchChallenge.mockResolvedValueOnce(savingsFixture(false)).mockResolvedValue({ ...savingsFixture(false), offer: { ...savingsFixture(false).offer!, policy_version: 'dev-notice-v2', personal_ends_on: '2027-01-02' } })
    render(view()); await screen.findByText('Join the 90-day savings challenge')
    fireEvent.click(screen.getByLabelText(/accept joining the challenge/)); fireEvent.click(screen.getByLabelText(/start later than the group/))
    fireEvent(window, new Event('focus'))
    await screen.findByText('The joining details were updated. Review them and check the boxes again.')
    expect((screen.getByLabelText(/accept joining the challenge/) as HTMLInputElement).checked).toBe(false)
    expect((screen.getByRole('button', { name: 'Accept and join' }) as HTMLButtonElement).disabled).toBe(true)
  })
  it('rejects future actuals and fractional cents without a draft write', async () => {
    render(view()); await screen.findByText('No target yet')
    const form = screen.getByRole('region', { name: 'Add money you set aside' }).querySelector('form')!
    fireEvent.change(screen.getByLabelText('Amount in US dollars'), { target: { value: '1.005' } })
    fireEvent.submit(form)
    await screen.findByText(/at most two decimal places/)
    fireEvent.change(screen.getByLabelText('Amount in US dollars'), { target: { value: '1.00' } })
    fireEvent.change(screen.getByLabelText('Date you set it aside or took it out'), { target: { value: '2026-10-05' } })
    fireEvent.submit(form)
    await screen.findByText(/A future date can’t be saved yet/)
    expect(api.stageSavingsEntry).not.toHaveBeenCalled()
  })
  it('shows signed negative server totals with a zero bar and no zero attestation shortcut', async () => {
    const fixture = savingsFixture(); fixture.projection = { ...fixture.projection!, reporting_known: true, reported_cents: -2550, evidence_supported_cents: 0, progress_basis_points: 0 }
    fetchChallenge.mockResolvedValue(fixture)
    render(view()); await screen.findByText('-$25.50')
    expect(screen.getByRole('progressbar').getAttribute('value')).toBe('0')
    expect(screen.queryByRole('button', { name: 'Confirm nothing set aside' })).toBeNull()
  })
  it('preserves typed inputs on a transient background failure and disables changes until refreshed', async () => {
    render(view()); await screen.findByText('No target yet')
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
    render(view()); await screen.findByText('No target yet')
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

it('offers evidence review only for current positive eligible entries and displays returned quality honestly',async()=>{const review=vi.fn();fetchPage.mockImplementation(async collection=>({records:collection==='entries'?[{id:41,lock_version:1,current_approved_version_id:51,current_approved_version:{...savingsEntryVersion(),evidence_status:'stale',evidence_supported_cents:0}},{id:42,lock_version:1,current_approved_version_id:52,current_approved_version:{...savingsEntryVersion(),id:52,funding_source:'borrowed'}},{id:43,lock_version:1,current_approved_version_id:53,current_approved_version:{...savingsEntryVersion(),id:53,signed_cents:-500,funding_source:'withdrawal'}}]:[],next_cursor:null}));render(<SavingsChallengeHome onAskMia={vi.fn()} onReviewStatements={vi.fn()} onReviewEvidence={review}/>);await screen.findByText(/Statement match needs another look/);expect(screen.getAllByRole('button',{name:/^(Match to a statement|Review statement match)$/})).toHaveLength(1);fireEvent.click(screen.getByRole('button',{name:'Review statement match'}));expect(review).toHaveBeenCalledWith(51);const history=screen.getByRole('region',{name:'Savings history'});expect(within(history).getByText(/Borrowed money — excluded/)).toBeTruthy();expect(within(history).getByText(/Withdrawal from challenge savings/)).toBeTruthy();expect(document.body.textContent).toContain('$25.50 · Sun, Oct 4')})
it('pages approved entry revisions and opens optional proof review for an old eligible contribution without editing totals',async()=>{const reviewed=vi.fn();const old={...savingsEntryVersion(5000),id:11,reason:'Earlier approved contribution'};fetchPage.mockImplementation(async(collection,cursor)=>({records:collection==='entry_versions'?(cursor?[old]:[{...old,id:8,funding_source:'borrowed'}]):[],next_cursor:collection==='entry_versions'&&!cursor?8:null}));render(<SavingsChallengeHome onAskMia={vi.fn()} onReviewStatements={vi.fn()} onReviewEvidence={reviewed}/>);await screen.findByText('No target yet');fireEvent.click(screen.getByText('Earlier versions of your records',{exact:true}));const history=screen.getByRole('region',{name:'Earlier versions'});await within(history).findByText(/Borrowed money/);expect(within(history).queryByRole('button',{name:/Review statement match for/})).toBeNull();fireEvent.click(within(history).getByRole('button',{name:'Next records'}));fireEvent.click(await within(history).findByRole('button',{name:'Review statement match for version 1'}));expect(reviewed).toHaveBeenCalledWith(11);expect(screen.getByRole('article',{name:'Approved savings progress'}).textContent).toContain('No amounts added yet');expect(api.stageSavingsEntry).not.toHaveBeenCalled()})

it('keeps approved Home compact, preserves a collapsed entry draft and omits one-page pagination', async () => {
  const fixture = savingsFixture(); fixture.accepted_plan = { ...savingsPlanDraft(), id: 21, target_cents: 50000 } as unknown as NonNullable<typeof fixture.accepted_plan>
  fixture.enrollment!.current_accepted_plan_version_id = 21
  fetchChallenge.mockResolvedValue(fixture)
  const entries = [{ id: 41, lock_version: 1, current_approved_version_id: 51, current_approved_version: savingsEntryVersion() }]
  let finishHistory!: (rows: typeof entries) => void
  fetchPage.mockImplementation(async collection => ({ records: collection === 'entries' ? await new Promise<typeof entries>(resolve => { finishHistory = resolve }) : [], next_cursor: null }))
  render(view())
  const toggle = await screen.findByRole('button', { name: 'I set money aside' })
  const entry = screen.getByRole('region', { name: 'Add money you set aside', hidden: true })
  const target = screen.getByText('Your target & spending choices').closest('details')!
  expect(toggle.getAttribute('aria-expanded')).toBe('false'); expect(entry.classList.contains('is-collapsed')).toBe(true); expect(target.open).toBe(false)
  expect(toggle.getAttribute('aria-controls')).toBe(entry.id)
  fireEvent.click(toggle)
  expect(toggle.getAttribute('aria-expanded')).toBe('true'); expect(entry.classList.contains('is-collapsed')).toBe(false)
  const amount = screen.getByLabelText('Amount in US dollars') as HTMLInputElement
  fireEvent.change(amount, { target: { value: '12.34' } })
  fireEvent.click(toggle)
  fireEvent.click(toggle)
  expect(amount.value).toBe('12.34')
  const approved = screen.getByText('Your records & corrections').closest('details')!
  fireEvent.click(approved.querySelector('summary')!)
  const history = screen.getByRole('region', { name: 'Savings history', hidden: true })
  expect(within(history).getByText('Loading savings history…')).toBeTruthy()
  await act(async () => finishHistory(entries))
  await waitFor(() => expect(screen.queryAllByText(/^Loading .*…$/)).toHaveLength(0))
  expect(within(history).getByRole('button', { name: 'Fix the $25.50 set aside on Sun, Oct 4' })).toBeTruthy()
  expect(screen.queryByRole('button', { name: 'Previous records' })).toBeNull()
  expect(api.stageSavingsEntry).not.toHaveBeenCalled()
})
