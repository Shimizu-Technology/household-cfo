import { describe, expect, it, vi } from 'vitest'
import { ApiRequestError, type AppData } from '../api'
import { confirmAfterCreate, isPossibleDuplicateRefusal, reloadReviewData } from './confirmRefusal'

const workspace = { budget: { annual_plan: { year: 2026 } } } as unknown as AppData
const refusal = () => new ApiRequestError('This looks like Payless Supermarkets on Aug 3 ($103.42), which you already have.', { status: 409, code: 'possible_duplicate' })

describe('confirmAfterCreate', () => {
  it('asks "Same purchase?" when the retry after a lost response is refused as a possible duplicate', async () => {
    const confirm = vi.fn<() => Promise<AppData>>()
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockRejectedValueOnce(refusal())

    await expect(confirmAfterCreate(confirm)).resolves.toEqual({ kind: 'asking' })
    // The caller's closure reuses one idempotency key; the helper only asks twice.
    expect(confirm).toHaveBeenCalledTimes(2)
  })

  it('asks without retrying when the first answer is the refusal', async () => {
    const confirm = vi.fn<() => Promise<AppData>>().mockRejectedValueOnce(refusal())
    await expect(confirmAfterCreate(confirm)).resolves.toEqual({ kind: 'asking' })
    expect(confirm).toHaveBeenCalledTimes(1)
  })

  it('retries a lost response once and reports a finished confirmation', async () => {
    const confirm = vi.fn<() => Promise<AppData>>().mockRejectedValueOnce(new ApiRequestError('Bad gateway', { status: 502 })).mockResolvedValueOnce(workspace)
    await expect(confirmAfterCreate(confirm)).resolves.toEqual({ kind: 'confirmed', workspace })
    expect(confirm).toHaveBeenCalledTimes(2)
  })

  it('leaves other refusals unfinished without asking again, and an unknown retry unfinished', async () => {
    const refused = vi.fn<() => Promise<AppData>>().mockRejectedValueOnce(new ApiRequestError('Choose a category', { status: 422 }))
    await expect(confirmAfterCreate(refused)).resolves.toEqual({ kind: 'unfinished' })
    expect(refused).toHaveBeenCalledTimes(1)

    const offline = vi.fn<() => Promise<AppData>>().mockRejectedValue(new TypeError('Failed to fetch'))
    await expect(confirmAfterCreate(offline)).resolves.toEqual({ kind: 'unfinished' })
    expect(offline).toHaveBeenCalledTimes(2)
  })
})

describe('reloadReviewData', () => {
  const steps = (overrides: Partial<Parameters<typeof reloadReviewData>[0]> = {}) => ({
    fetchLatest: vi.fn().mockResolvedValue(workspace),
    isCurrent: vi.fn().mockReturnValue(true),
    apply: vi.fn(),
    restoreSelectedYear: vi.fn().mockResolvedValue(true),
    refreshDocuments: vi.fn().mockResolvedValue(true),
    ...overrides,
  })

  it('is current only when the selected budget year reloaded too', async () => {
    const ok = steps()
    await expect(reloadReviewData(ok)).resolves.toBe(true)
    expect(ok.apply).toHaveBeenCalledWith(workspace)
    expect(ok.restoreSelectedYear).toHaveBeenCalledWith(workspace)
  })

  it('keeps the refusal visible when the selected prior year fails to reload', async () => {
    const priorYearFailed = steps({ restoreSelectedYear: vi.fn().mockResolvedValue(false) })
    await expect(reloadReviewData(priorYearFailed)).resolves.toBe(false)
  })

  it('keeps the refusal visible when the receipt or statement behind the card fails to reload', async () => {
    const documentFailed = steps({ refreshDocuments: vi.fn().mockResolvedValue(false) })
    await expect(reloadReviewData(documentFailed)).resolves.toBe(false)
    expect(documentFailed.restoreSelectedYear).toHaveBeenCalled()
  })

  it('keeps the refusal visible when offline or overtaken by a newer change', async () => {
    const offline = steps({ fetchLatest: vi.fn().mockRejectedValue(new TypeError('Failed to fetch')) })
    await expect(reloadReviewData(offline)).resolves.toBe(false)
    expect(offline.apply).not.toHaveBeenCalled()

    const overtaken = steps({ isCurrent: vi.fn().mockReturnValue(false) })
    await expect(reloadReviewData(overtaken)).resolves.toBe(false)
    expect(overtaken.apply).not.toHaveBeenCalled()
    expect(overtaken.restoreSelectedYear).not.toHaveBeenCalled()
    expect(overtaken.refreshDocuments).not.toHaveBeenCalled()
  })
})

it('recognizes only the possible-duplicate refusal', () => {
  expect(isPossibleDuplicateRefusal(refusal())).toBe(true)
  expect(isPossibleDuplicateRefusal(new ApiRequestError('Changed elsewhere', { status: 409, code: 'changed_elsewhere' }))).toBe(false)
  expect(isPossibleDuplicateRefusal(new TypeError('Failed to fetch'))).toBe(false)
})
