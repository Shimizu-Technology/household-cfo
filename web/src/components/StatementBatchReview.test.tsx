// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { StatementBatchReview } from './StatementBatchReview'
import { participantReviewFixture } from '../../e2e/sourceReviewFixtures'
import type { ParticipantSourceReview, PendingSourceDraft } from '../lib/participantSourceReview'

afterEach(cleanup)
function fixture() {
  const data = participantReviewFixture()
  const event = data.events.find((row) => row.id === 4003)!
  const context = data.participant_review!
  const facts = { source_account_identity_version_id: 100, disposition: 'include' as const, event_type: 'purchase' as const,
    signed_amount_cents: -2_159, purchase_amount_cents: 100_000, posted_on: '2026-09-15', authorized_on: '2026-09-14',
    merchant: 'Reviewed fictional merchant', budget_category_id: 10, overlap_disposition: 'canonical' as const, external_reference: 'synthetic-ref', matched_version_id: null }
  context.rows[event.id] = { head: { id: 9, approved_version_id: 301, lock_version: 4 }, pending: null,
    approved: { id: 301, digest: 'old-approved', version_number: 1, facts, reason: 'Original review', projection: { action: 'create' }, actual: { id: 61, digest: 'recorded-expense', amount_cents: 100_000 } } }
  return { event, context, facts }
}
function corrected(context: ParticipantSourceReview) {
  const next = structuredClone(context)
  next.accounts[0].approved = { ...next.accounts[0].approved!, id: 101, digest: 'corrected-account', version_number: 2,
    tracked_account: { ...next.accounts[0].approved!.tracked_account, label: 'Corrected fictional account' } }
  next.accounts[0].head = { ...next.accounts[0].head, approved_version_id: 101, lock_version: 2 }
  return next
}
function mount(context: ParticipantSourceReview, event = fixture().event, mutate = vi.fn().mockResolvedValue(true)) {
  const props = { events: [event], selected: [event.id], context, mutate, disabled: false, onRunning: vi.fn() }
  return { ...render(<StatementBatchReview {...props} />), props, mutate }
}
function confirm() {
  fireEvent.change(screen.getByLabelText('Selected-row review note'), { target: { value: 'Checked exact synthetic row.' } })
  fireEvent.click(screen.getByRole('checkbox', { name: /I checked every displayed account/ }))
}

describe('StatementBatchReview current account identity', () => {
  it('stages current identity v2 while preserving approved financial facts and spending', async () => {
    const { context, event, facts } = fixture()
    const { mutate } = mount(corrected(context), event)
    confirm()
    fireEvent.click(screen.getByRole('button', { name: 'Save selected row proposals' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledOnce())
    expect(mutate).toHaveBeenCalledWith('stage', { event_id: event.id, base_version_id: 301, base_lock_version: 4,
      expected_pending_draft: null, facts: { ...facts, source_account_identity_version_id: 101 }, projection: { action: 'none' }, reason: 'Checked exact synthetic row.' })
    expect(context.rows[event.id].approved!.facts).toEqual(facts)
    expect(screen.getByText(/Current reviewed account: Corrected fictional account.*Bank \/ wallet/)).toBeTruthy()
    const technical = screen.getByText('Review record details').closest('details')!
    expect(technical.open).toBe(false)
    expect(technical.textContent).toMatch(/version 2.*identity ID 101/)
    fireEvent.click(screen.getByText('Review record details'))
    expect(technical.textContent).toMatch(/Saved facts account identity ID: 101/)

    expect(screen.getByText(/Spending: unchanged at \$1,000.00/)).toBeTruthy()
  })
  it('requires a new confirmation when the reviewed account changes without a row-head change', () => {
    const { context, event } = fixture()
    const { rerender, props, mutate } = mount(context, event)
    confirm()
    expect((screen.getByRole('button', { name: 'Save selected row proposals' }) as HTMLButtonElement).disabled).toBe(false)
    rerender(<StatementBatchReview {...props} context={corrected(context)} />)
    expect((screen.getByRole('checkbox', { name: /I checked every displayed account/ }) as HTMLInputElement).checked).toBe(false)
    expect((screen.getByRole('button', { name: 'Save selected row proposals' }) as HTMLButtonElement).disabled).toBe(true)
    expect(mutate).not.toHaveBeenCalled()
  })
  it('never rewrites or approves a saved pending v1 proposal under current v2 even without the current flag', () => {
    const { context, event, facts } = fixture()
    const next = corrected(context)
    const pending: PendingSourceDraft = { id: 801, digest: 'old-pending', lock_version: 1, status: 'pending', facts: { ...facts }, reason: 'Historical pending proposal', projection: { action: 'create' } }
    next.rows[event.id].pending = pending
    const { mutate } = mount(next, event)
    confirm()
    expect((screen.getByRole('button', { name: 'Approve selected saved proposals' }) as HTMLButtonElement).disabled).toBe(true)
    expect((screen.getByRole('button', { name: 'Save selected row proposals' }) as HTMLButtonElement).disabled).toBe(true)
    expect(screen.getByText(/Saved proposal account:.*requires individual review/)).toBeTruthy()
    expect(next.rows[event.id].pending).toEqual(pending)
    expect(mutate).not.toHaveBeenCalled()
  })
  it('allows exact current pending approval without altering its saved facts or projection', async () => {
    const { context, event, facts } = fixture()
    const next = corrected(context)
    const pending: PendingSourceDraft = { id: 801, digest: 'current-pending', lock_version: 2, status: 'pending', facts: { ...facts, source_account_identity_version_id: 101 }, reason: 'Exact current identity', projection: { action: 'none' } }
    next.rows[event.id].pending = pending
    const { mutate } = mount(next, event)
    confirm()
    fireEvent.click(screen.getByRole('button', { name: 'Approve selected saved proposals' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledWith('approve', { draft_id: 801, draft_digest: 'current-pending', draft_lock_version: 2 }))
    expect(next.rows[event.id].pending).toEqual(pending)
  })
  it('stops the remaining selected rows if account context changes while a request is in flight', async () => {
    const { context, event } = fixture()
    const second = { ...event, id: 4005, position: 5 }
    context.rows[second.id] = structuredClone(context.rows[event.id])
    let finish!: (value: boolean) => void
    const mutate = vi.fn().mockImplementation(() => new Promise<boolean>((resolve) => { finish = resolve }))
    const props = { events: [event, second], selected: [event.id, second.id], context, mutate, disabled: false, onRunning: vi.fn() }
    const { rerender } = render(<StatementBatchReview {...props} />)
    confirm()
    fireEvent.click(screen.getByRole('button', { name: 'Save selected row proposals' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledOnce())
    rerender(<StatementBatchReview {...props} context={corrected(context)} />)
    finish(true)
    await screen.findByText(/Stopped after 1 of 2/)
    expect(mutate).toHaveBeenCalledOnce()
  })
  it('stops an old batch after a keyed remount while its first request is pending', async () => {
    const { context, event } = fixture()
    const second = { ...event, id: 4005, position: 5 }
    context.rows[second.id] = structuredClone(context.rows[event.id])
    let finish!: (value: boolean) => void
    const mutate = vi.fn().mockImplementation(() => new Promise<boolean>((resolve) => { finish = resolve }))
    const onRunning = vi.fn()
    const props = { events: [event, second], selected: [event.id, second.id], context, mutate, disabled: false, onRunning }
    const { rerender } = render(<StatementBatchReview key="old-row-context" {...props} />)
    confirm()
    fireEvent.click(screen.getByRole('button', { name: 'Save selected row proposals' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledOnce())
    rerender(<StatementBatchReview key="new-row-context" {...props} context={corrected(context)} />)
    finish(true)
    await waitFor(() => expect(onRunning).toHaveBeenLastCalledWith(false))
    expect(mutate).toHaveBeenCalledOnce()
    expect((screen.getByRole('checkbox', { name: /I checked every displayed account/ }) as HTMLInputElement).checked).toBe(false)
  })
  it('requires renewed confirmation when a displayed category name changes', () => {
    const { context, event } = fixture()
    const { rerender, props } = mount(context, event)
    confirm()
    const next = structuredClone(context)
    next.categories[0].name = 'Corrected fictional category'
    rerender(<StatementBatchReview {...props} context={next} />)
    expect((screen.getByRole('checkbox', { name: /I checked every displayed account/ }) as HTMLInputElement).checked).toBe(false)
    expect((screen.getByRole('button', { name: 'Save selected row proposals' }) as HTMLButtonElement).disabled).toBe(true)
  })

})
