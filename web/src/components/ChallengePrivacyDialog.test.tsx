import { StrictMode } from 'react'
// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ChallengePrivacyDialog } from './ChallengePrivacyDialog'
import { privacyFixture, privacyScope, syntheticPrivacyApi } from '../test/privacyFixtures'
import { savePrivacyRecovery } from '../lib/privacyRecovery'
import { ApiRequestError } from '../api'
beforeEach(() => { sessionStorage.clear(); HTMLDialogElement.prototype.showModal = function () { this.open = true }; HTMLDialogElement.prototype.close = function () { this.open = false } })
afterEach(cleanup)
const approve = () => { fireEvent.click(screen.getByRole('checkbox', { name: 'I understand and approve this exact change.' })); fireEvent.click(screen.getByRole('button', { name: 'Approve reviewed change' })) }
function open(api = syntheticPrivacyApi()) { return render(<ChallengePrivacyDialog actorScope={privacyScope} participant onClose={vi.fn()} documentImportId={500} api={api} />) }
describe('participant privacy help and reminders', () => {
  it('does not consent by default and separately reviews exact recipient before a write', async () => {
    const api = syntheticPrivacyApi(); api.mutate = vi.fn(api.mutate); open(api)
    await screen.findByText('No sharing grants.'); expect(api.mutate).not.toHaveBeenCalled()
    fireEvent.change(screen.getByLabelText('Exact recipient'), { target: { value: '903' } }); fireEvent.click(screen.getByRole('button', { name: 'Review sharing choice' }))
    expect(screen.getByText('Recipient: Fictional Mel')).toBeTruthy(); expect(api.mutate).not.toHaveBeenCalled(); approve()
    await waitFor(() => expect(api.mutate).toHaveBeenCalledWith(expect.objectContaining({ action: 'consent' }), expect.objectContaining({ granted: true, recipient_user_id: 903, selected_records: [] }), expect.any(AbortSignal)))
  })
  it('selected sharing reviews the ENTIRE record and keeps feelings unsupported', async () => {
    const api = syntheticPrivacyApi(); api.mutate = vi.fn(api.mutate); open(api); await screen.findByLabelText('Purpose')
    fireEvent.change(screen.getByLabelText('Purpose'), { target: { value: 'selected_details' } }); fireEvent.change(screen.getByLabelText('Exact recipient'), { target: { value: '903' } })
    fireEvent.click(screen.getAllByRole('button', { name: 'Find exact records' })[0]); fireEvent.click(await screen.findByRole('checkbox', { name: /Fictional sample statement/ }))
    fireEvent.click(screen.getByRole('button', { name: 'Review sharing choice' })); expect(screen.getByText(/Share ENTIRE selected records/)).toBeTruthy(); expect(screen.queryByRole('option', { name: 'Feelings' })).toBeNull(); approve()
    await waitFor(() => expect(api.mutate).toHaveBeenCalledWith(expect.anything(), expect.objectContaining({ kind: 'selected_details', selected_records: [{ record_type: 'document_source', record_id: 500 }], expires_at: expect.any(String) }), expect.anything()))
  })
  it('self-only metadata erasure is reviewed without reading feeling or purchase content', async () => {
    const api = syntheticPrivacyApi(); api.mutate = vi.fn(api.mutate); open(api); fireEvent.click(await screen.findByText('Erase optional feelings'))
    fireEvent.click(screen.getByRole('button', { name: 'Review erase reflection 700' })); expect(screen.getByText(/All historical optional feeling text/)).toBeTruthy(); approve()
    await waitFor(() => expect(api.mutate).toHaveBeenCalledWith(expect.objectContaining({ action: 'erase', reflectionId: 700 }), { erase_accepted: true, expected_version_id: 701, expected_head_lock_version: 2 }, expect.anything()))
  })
  it('timeout requires status first and retries unchanged payload with original identity', async () => {
    const api = syntheticPrivacyApi(); api.mutate = vi.fn().mockRejectedValueOnce(new Error('network lost')).mockResolvedValue({}); api.status = vi.fn().mockResolvedValue({ state: 'unknown' as const, actor_scope: privacyScope }); open(api)
    await screen.findByLabelText('Purpose'); fireEvent.change(screen.getByLabelText('Exact recipient'), { target: { value: '903' } }); fireEvent.click(screen.getByRole('button', { name: 'Review sharing choice' })); approve()
    await screen.findByText(/server did not confirm/); expect((screen.getByRole('button', { name: 'Approve reviewed change' }) as HTMLButtonElement).disabled).toBe(true)
    expect(screen.queryByRole('button', { name: 'Retry exact reviewed request' })).toBeNull(); fireEvent.click(screen.getByRole('button', { name: 'Check earlier request' })); fireEvent.click(await screen.findByRole('button', { name: 'Retry exact reviewed request' }));
    await waitFor(() => expect(api.mutate).toHaveBeenCalledTimes(2)); expect(vi.mocked(api.mutate).mock.calls[1].slice(0, 2)).toEqual(vi.mocked(api.mutate).mock.calls[0].slice(0, 2)); expect(sessionStorage.getItem('challenge-private-request-identity-v1')).toBeNull()
  })
  it('cold unknown recovery holds identity and permits only a newly reviewed matching action', async () => {
    savePrivacyRecovery({ scope: privacyScope, enrollmentId: 100, action: 'consent', key: 'cold-original' })
    const api = syntheticPrivacyApi(); api.mutate = vi.fn(api.mutate); api.status = vi.fn(async () => ({ state: 'unknown' as const, actor_scope: privacyScope })); open(api)
    await screen.findByLabelText('Purpose'); expect((screen.getByRole('button', { name: 'Review sharing choice' }).closest('fieldset') as HTMLFieldSetElement).disabled).toBe(true)
    fireEvent.click(screen.getByRole('button', { name: 'Check earlier request' })); await screen.findByText(/Re-review the same action/)
    fireEvent.change(screen.getByLabelText('Exact recipient'), { target: { value: '903' } }); fireEvent.click(screen.getByRole('button', { name: 'Review sharing choice' })); approve()
    await waitFor(() => expect(api.mutate).toHaveBeenCalledWith(expect.objectContaining({ key: 'cold-original' }), expect.anything(), expect.anything()))
  })
  it('identity switch immediately clears support buffers and ignores late old responses', async () => {
    const api = syntheticPrivacyApi(); let resolve!: (value: typeof privacyFixture) => void; api.privacy = vi.fn(() => new Promise<typeof privacyFixture>((done) => { resolve = done })); const view = open(api)
    await waitFor(() => expect(api.privacy).toHaveBeenCalled()); view.rerender(<ChallengePrivacyDialog actorScope={{ ...privacyScope, user_id: 999 }} participant={false} onClose={vi.fn()} api={api} />)
    resolve({ ...privacyFixture, support_requests: [{ id: 1, message: 'Old private message', issue_kind: 'technical', recipient_user_id: 904, status: 'open', selected_records: [], lock_version: 0, created_at: '2026-11-01T00:00:00Z' }] })
    await waitFor(() => expect(screen.queryByText('Old private message')).toBeNull()); expect(screen.getByText(/available only to the participant/)).toBeTruthy()
  })
  it('global source revocation names every affected use and retains approved facts disclosure', async () => {
    const api = syntheticPrivacyApi(); api.mutate = vi.fn(api.mutate); open(api); fireEvent.click(await screen.findByText('Original source use')); fireEvent.click(screen.getByRole('button', { name: 'Review source 500 use' })); fireEvent.click(await screen.findByRole('button', { name: 'Review global source revocation' }));
    expect(screen.getByText(/ALL affected enrollments/)).toBeTruthy(); expect(screen.getByText(/Enrollment 200:/)).toBeTruthy(); expect(screen.getByText(/Physical cleanup may remain pending/)).toBeTruthy(); approve()
    await waitFor(() => expect(api.mutate).toHaveBeenCalledWith(expect.objectContaining({ action: 'source_revoke' }), { enrollment_id: 100, document_import_id: 500, expected_affected_uses_digest: 'a'.repeat(64) }, expect.anything()))
  })
  it('reminder dismissal is distinct from a check-in and email consent remains optional', async () => {
    const api = syntheticPrivacyApi(); api.mutate = vi.fn(api.mutate); open(api); fireEvent.click(await screen.findByText('Daily reminders')); await screen.findByText(/Email delivery is not configured/)
    expect((screen.getByRole('checkbox', { name: /I consent to a generic daily email/ }) as HTMLInputElement).checked).toBe(false)
    fireEvent.click(screen.getByRole('button', { name: 'Review dismiss reminder' })); expect(screen.getByText(/Dismissal does not record spending/)).toBeTruthy(); approve()
    await waitFor(() => expect(api.mutate).toHaveBeenCalledWith(expect.objectContaining({ action: 'dismiss' }), { enrollment_id: 100, reminder_id: 800, expected_lock_version: 0 }, expect.anything()))
  })
  it('help request shares no extra records by default and clears its text after review', async () => {
    const api = syntheticPrivacyApi(); api.mutate = vi.fn(api.mutate); open(api); fireEvent.click(await screen.findByText('Ask for help'))
    fireEvent.change(screen.getByLabelText('Help recipient'), { target: { value: '904' } }); fireEvent.change(screen.getByLabelText('Your message'), { target: { value: 'Fictional technical help only' } }); fireEvent.click(screen.getByRole('button', { name: 'Review help request' }))
    expect(screen.getByText(/Creating a request does not grant access/)).toBeTruthy(); expect(api.mutate).not.toHaveBeenCalled(); approve()
    await waitFor(() => expect(api.mutate).toHaveBeenCalledWith(expect.objectContaining({ action: 'support_request' }), expect.objectContaining({ recipient_user_id: 904, message: 'Fictional technical help only', selected_records: [] }), expect.anything()))
    expect(sessionStorage.getItem('challenge-private-request-identity-v1') ?? '').not.toContain('Fictional technical help only')
  })
  it('source authorization uses the exact server expiry and optimistic locks', async () => {
    const api = syntheticPrivacyApi(); api.mutate = vi.fn(api.mutate); open(api); fireEvent.click(await screen.findByText('Original source use')); fireEvent.click(screen.getByRole('button', { name: 'Review source 500 use' })); fireEvent.click(await screen.findByRole('button', { name: 'Review authorize source use' })); approve()
    await waitFor(() => expect(api.mutate).toHaveBeenCalledWith(expect.objectContaining({ action: 'source_authorize' }), expect.objectContaining({ document_import_id: 500, expected_expires_at: '2027-02-28T13:59:59Z', expected_use_id: 601, expected_lock_version: 1 }), expect.anything()))
  })
  it('temporary access is a separate exact-record approval for the existing ticket recipient', async () => {
    const api = syntheticPrivacyApi(); api.mutate = vi.fn(api.mutate)
    api.privacy = vi.fn(async (): Promise<typeof privacyFixture> => ({ ...privacyFixture, support_requests: [{ id: 40, recipient_user_id: 904, issue_kind: 'technical', message: 'Fictional issue', selected_records: [], status: 'open', lock_version: 4, created_at: '2026-11-01T00:00:00Z' }] }))
    open(api); fireEvent.click(await screen.findByText('Ask for help')); const grantToggle = screen.getByText('Grant exact records for this ticket'); fireEvent.click(grantToggle); const grantForm = within(grantToggle.closest('details')!)
    fireEvent.click(grantForm.getByRole('button', { name: 'Find exact records' })); fireEvent.click(await screen.findByRole('checkbox', { name: /Fictional sample statement/ })); fireEvent.change(screen.getByLabelText('Reason for record access'), { target: { value: 'Fictional bounded review' } })
    fireEvent.change(screen.getByLabelText('Support duration'), { target: { value: '24' } }); fireEvent.click(screen.getByRole('button', { name: 'Review temporary support access' })); expect(screen.getByText('Recipient: Fictional Leon')).toBeTruthy(); expect(screen.getByText(/at most 24 hours/)).toBeTruthy(); approve()
    await waitFor(() => expect(api.mutate).toHaveBeenCalledWith(expect.objectContaining({ action: 'support_grant' }), expect.objectContaining({ ticket_id: 40, recipient_user_id: 904, expected_ticket_lock_version: 4, reason: 'Fictional bounded review', selected_records: [{ record_type: 'document_source', record_id: 500 }] }), expect.anything()))
    const expires = Date.parse((vi.mocked(api.mutate).mock.calls[0][1] as { expires_at: string }).expires_at); expect(expires - Date.now()).toBeLessThanOrEqual(24 * 3600000)
  })
  it('wrong actor response cannot render private support text', async () => {
    const api = syntheticPrivacyApi(); api.privacy = vi.fn(async () => ({ ...privacyFixture, actor_scope: { ...privacyScope, household_id: 999 }, support_requests: [{ id: 40, recipient_user_id: 904, issue_kind: 'other', message: 'Never render this foreign message', selected_records: [], status: 'open', lock_version: 0, created_at: '2026-11-01T00:00:00Z' }] }))
    open(api); await screen.findByText(/belongs to a different account/); expect(screen.queryByText('Never render this foreign message')).toBeNull()
  })
  it('an explicitly requested enrollment beyond the first metadata page does not open another program', async () => {
    const api = syntheticPrivacyApi(); const first = await api.controls(); api.controls = vi.fn(async (cursor) => cursor ? { ...first, records: [{ ...first.records[0], id: 101 }], next_cursor: null } : { ...first, next_cursor: 100 }); api.privacy = vi.fn(api.privacy)
    render(<ChallengePrivacyDialog actorScope={privacyScope} participant initialEnrollmentId={101} onClose={vi.fn()} api={api} />); await screen.findByText('No sharing grants.')
    expect(api.controls).toHaveBeenCalledTimes(2); expect(api.privacy).toHaveBeenCalledWith(101, null, expect.anything())
  })
  it('held candidates do not hide existing revocation or self-erasure controls', async () => {
    const api = syntheticPrivacyApi(); api.candidates = vi.fn(async () => { throw new ApiRequestError('Program held. New sharing unavailable.', { status: 403 }) }); api.privacy = vi.fn(async () => ({ ...privacyFixture, grants: [{ id: 20, kind: 'coach_summary' as const, recipient_user_id: 903, granted: true, selected_records: [], expires_at: null, policy_version: 'challenge_privacy_v1', lock_version: 3 }] })); open(api)
    await screen.findByRole('button', { name: 'Review revoke sharing' }); fireEvent.change(screen.getByLabelText('Purpose'), { target: { value: 'selected_details' } }); fireEvent.click(screen.getAllByRole('button', { name: 'Find exact records' })[0]); await screen.findByText('Program held. New sharing unavailable.')
    expect((screen.getByRole('button', { name: 'Review revoke sharing' }) as HTMLButtonElement).disabled).toBe(false); expect(screen.getByRole('button', { name: 'Review erase reflection 700', hidden: true })).toBeTruthy()
  })
})
it.each(['quota', 'disabled', 'silently ignored'])('does not send approved privacy choices when identity storage is %s', async mode => {
  const api = syntheticPrivacyApi(); api.mutate = vi.fn(api.mutate); open(api)
  await screen.findByLabelText('Purpose'); fireEvent.change(screen.getByLabelText('Exact recipient'), { target: { value: '903' } }); fireEvent.click(screen.getByRole('button', { name: 'Review sharing choice' }))
  const storage = mode === 'disabled' ? vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => { throw new DOMException('Disabled', 'SecurityError') }) : vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { if (mode === 'quota') throw new DOMException('Quota', 'QuotaExceededError') })
  try { approve(); await screen.findByText(/No change was submitted/); expect(api.mutate).not.toHaveBeenCalled(); expect(screen.queryByRole('button', { name: 'Check earlier request' })).toBeNull() } finally { storage.mockRestore() }
  fireEvent.click(screen.getByRole('button', { name: 'Approve reviewed change' })); await waitFor(() => expect(api.mutate).toHaveBeenCalledOnce())
})
it('retains a cold original key after changed-input conflict until original status is reconciled', async () => {
  const identity = { scope: privacyScope, enrollmentId: 100, action: 'consent' as const, key: 'cold-conflict' }
  savePrivacyRecovery(identity)
  const api = syntheticPrivacyApi(); api.mutate = vi.fn().mockRejectedValue(new ApiRequestError('Fingerprint conflicts', { status: 409 })); api.status = vi.fn().mockResolvedValueOnce({ state: 'unknown', can_retry: true, actor_scope: privacyScope }).mockResolvedValue({ state: 'committed', actor_scope: privacyScope }); open(api)
  await screen.findByLabelText('Purpose'); fireEvent.click(screen.getByRole('button', { name: 'Check earlier request' })); await screen.findByText(/Re-review the same action/)
  fireEvent.change(screen.getByLabelText('Exact recipient'), { target: { value: '903' } }); fireEvent.click(screen.getByRole('button', { name: 'Review sharing choice' })); approve()
  await screen.findByText(/fresh review conflicted/); expect(sessionStorage.getItem('challenge-private-request-identity-v1')).toContain('cold-conflict'); expect(api.mutate).toHaveBeenCalledWith(identity, expect.anything(), expect.anything())
  expect(((await screen.findByRole('button', { name: 'Review sharing choice' })).closest('fieldset') as HTMLFieldSetElement).disabled).toBe(true)
  fireEvent.click(screen.getByRole('button', { name: 'Check earlier request' })); await screen.findByText('The earlier request was saved once.'); expect(api.mutate).toHaveBeenCalledOnce(); expect(api.status).toHaveBeenLastCalledWith(identity, expect.anything()); expect(sessionStorage.getItem('challenge-private-request-identity-v1')).toBeNull()
})
it('clears a first-attempt definitive conflict and requires a fresh review', async () => {
  const api = syntheticPrivacyApi(); api.mutate = vi.fn().mockRejectedValue(new ApiRequestError('Fresh choices stale', { status: 409 })); open(api)
  await screen.findByLabelText('Purpose'); fireEvent.change(screen.getByLabelText('Exact recipient'), { target: { value: '903' } }); fireEvent.click(screen.getByRole('button', { name: 'Review sharing choice' })); approve()
  await screen.findByText('Fresh choices stale'); expect(sessionStorage.getItem('challenge-private-request-identity-v1')).toBeNull(); expect(screen.queryByRole('button', { name: 'Approve reviewed change' })).toBeNull()
})


describe('privacy request ownership under effect replay', () => {
  it('ignores aborted metadata and program requests in StrictMode without hiding valid controls', async () => {
    const api = syntheticPrivacyApi()
    const originalControls = api.controls; const originalPrivacy = api.privacy
    api.controls = vi.fn((cursor, signal) => new Promise<Awaited<ReturnType<typeof originalControls>>>((resolve, reject) => {
      signal?.addEventListener('abort', () => reject(new Error('Metadata could not reach the API')), { once: true })
      queueMicrotask(() => { if (!signal?.aborted) void originalControls(cursor, signal).then(resolve, reject) })
    }))
    api.privacy = vi.fn((id, cursor, signal) => new Promise<Awaited<ReturnType<typeof originalPrivacy>>>((resolve, reject) => {
      signal?.addEventListener('abort', () => reject(new Error('Privacy could not reach the API')), { once: true })
      queueMicrotask(() => { if (!signal?.aborted) void originalPrivacy(id, cursor, signal).then(resolve, reject) })
    }))
    render(<StrictMode><ChallengePrivacyDialog actorScope={privacyScope} participant onClose={vi.fn()} api={api} /></StrictMode>)
    await screen.findByText('No sharing grants.')
    expect(screen.queryByText('Metadata could not reach the API')).toBeNull()
    expect(screen.queryByText('Privacy could not reach the API')).toBeNull()
    expect(api.controls).toHaveBeenCalledTimes(2)
    expect(api.privacy).toHaveBeenCalledTimes(2)
  })
  it('does not let a late failed first privacy request overwrite the current successful request', async () => {
    const api = syntheticPrivacyApi()
    let rejectEarlier: (error: Error) => void = () => {}
    api.privacy = vi.fn().mockImplementationOnce(() => new Promise((_resolve, reject) => { rejectEarlier = reject })).mockResolvedValue(privacyFixture)
    render(<StrictMode><ChallengePrivacyDialog actorScope={privacyScope} participant onClose={vi.fn()} api={api} /></StrictMode>)
    await screen.findByText('No sharing grants.')
    rejectEarlier(new Error('Earlier request failed after replay'))
    await waitFor(() => expect(screen.queryByText('Earlier request failed after replay')).toBeNull())
    expect(screen.getByText('No sharing grants.')).toBeTruthy()
  })
})
