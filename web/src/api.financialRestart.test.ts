import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { applyMiaActionDraft, confirmTransactionDraft, fetchDocumentSourceReview, fetchTrackedSourceAccounts, fetchFinancialBaseline, captureApiOperation, createIncomeSource, fetchAppData, fetchBudget, fetchFinancialRestartStatus, setActiveParticipantCohortId, setApiActorIdentity, setApiFinancialGeneration, setAuthTokenGetter, subscribeFinancialPictureChanges } from './api'

function json(value: unknown, generation?: number) {
  return new Response(JSON.stringify(value), { status: 200, headers: { 'Content-Type': 'application/json', ...(generation == null ? {} : { 'X-Financial-Generation': String(generation) }) } })
}
beforeEach(() => { setAuthTokenGetter(null); setApiActorIdentity(null); setActiveParticipantCohortId(null); setApiFinancialGeneration(null) })
afterEach(() => { setAuthTokenGetter(null); setApiActorIdentity(null); setActiveParticipantCohortId(null); setApiFinancialGeneration(null); vi.unstubAllGlobals() })

describe('financial picture request boundaries', () => {
  it.each([
    ['baseline', () => fetchFinancialBaseline()],
    ['source review', () => fetchDocumentSourceReview(1, 2, 1, 'all')],
    ['source accounts', () => fetchTrackedSourceAccounts(null)],
    ['Mia apply', () => applyMiaActionDraft(1, 'qa-review')],
    ['transaction apply', () => confirmTransactionDraft(1, {}, 'qa-transaction')],
  ])('refreshes the complete picture when a %s reply belongs to a newer generation', async (_name, operation) => {
    setApiFinancialGeneration(1)
    const changed = vi.fn(); const unsubscribe = subscribeFinancialPictureChanges(changed)
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(json({}, 2)))
    try { await expect(operation()).rejects.toThrow(/financial picture changed/); expect(changed).toHaveBeenCalledWith(2) } finally { unsubscribe() }
  })
  it('adopts a coherent workspace version and includes it on subsequent financial writes', async () => {
    const fetch = vi.fn().mockResolvedValueOnce(json({ workspace: { financial_generation: 2 } }, 2)).mockResolvedValueOnce(json({ income_source: { id: 1 } }, 2))
    vi.stubGlobal('fetch', fetch)
    await fetchAppData(true)
    await createIncomeSource({ label: 'Salary', source_type: 'job', amount: '0', cadence: 'monthly', starts_on: '2026-10-01' }, 2026, 'new-source')
    expect((fetch.mock.calls[1][1] as RequestInit).headers).toMatchObject({ 'X-Financial-Generation': '2' })
  })
  it('does not send an old operation after its authentication wait crosses a restart', async () => {
    let resolve!: (token: string) => void
    const token = new Promise<string>(done => { resolve = done })
    const fetch = vi.fn(); vi.stubGlobal('fetch', fetch)
    setApiFinancialGeneration(1); setAuthTokenGetter(() => token)
    const request = fetchBudget(2027)
    setApiFinancialGeneration(2); resolve('test-token')
    await expect(request).rejects.toThrow(/changed/)
    expect(fetch).not.toHaveBeenCalled()
  })
  it('rejects a new-picture budget reply and signals a full refresh instead of mixing snapshots', async () => {
    setApiFinancialGeneration(1)
    const changed = vi.fn(); const unsubscribe = subscribeFinancialPictureChanges(changed)
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(json({ financial_generation: 2 }, 2)))
    try { await expect(fetchBudget(2027)).rejects.toThrow(/financial picture changed/); expect(changed).toHaveBeenCalledWith(2) } finally { unsubscribe() }
  })
  it('drops an older reply without announcing a downgrade', async () => {
    setApiFinancialGeneration(2)
    const changed = vi.fn(); const unsubscribe = subscribeFinancialPictureChanges(changed)
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(json({ financial_generation: 1 }, 1)))
    try { await expect(fetchBudget(2027)).rejects.toThrow(/changed/); expect(changed).not.toHaveBeenCalled() } finally { unsubscribe() }
  })
  it('validates body versions when a proxy omits the response header', async () => {
    setApiFinancialGeneration(1)
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(json({ financial_generation: 2 })))
    await expect(fetchBudget(2027)).rejects.toThrow(/changed/)
  })
  it('refuses an internally inconsistent workspace snapshot', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(json({ workspace: { financial_generation: 1 } }, 2)))
    await expect(fetchAppData(true)).rejects.toThrow(/changed/)
  })
  it('does not carry a version into a different actor or program', async () => {
    setApiFinancialGeneration(2)
    const original = captureApiOperation()
    setApiActorIdentity('another-user'); setActiveParticipantCohortId(9)
    expect(original).toThrow(/changed/)
    const fetch = vi.fn().mockResolvedValue(json({})); vi.stubGlobal('fetch', fetch)
    await fetchBudget(2027)
    expect((fetch.mock.calls[0][1] as RequestInit).headers).not.toHaveProperty('X-Financial-Generation')
  })
  it('normalizes an exact pending receipt and never substitutes a new review', async () => {
    const receipt = { id: 13, status: 'pending', counts: { income_sources: 30 }, financial_generation: 1 }
    const fetch = vi.fn().mockResolvedValue(json({ financial_restart: { financial_generation: 1, latest_review: receipt } }, 1)); vi.stubGlobal('fetch', fetch)
    setApiFinancialGeneration(1)
    const result = await fetchFinancialRestartStatus(13)
    expect(result.review).toEqual(receipt)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(String(fetch.mock.calls[0][0])).toContain('/financial_restart/status?review_id=13')
  })
  it('permits exact applied receipt recovery across the committed version change', async () => {
    setApiFinancialGeneration(1)
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(json({ financial_restart: { financial_generation: 2, latest_review: { id: 13, status: 'applied', result_generation: 2 } } }, 2)))
    expect((await fetchFinancialRestartStatus(13)).review).toMatchObject({ id: 13, status: 'applied', result_generation: 2 })
  })
})
