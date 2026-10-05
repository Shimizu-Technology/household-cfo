// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { fetchDocumentImport } from '../api'
import type { ReviewedRow } from '../lib/participantSourceReview'
import { ReviewedSourcePreview } from './ReviewedSourcePreview'
vi.mock('../api', async (original) => ({ ...await original<typeof import('../api')>(), fetchDocumentImport: vi.fn() }))
vi.mock('./DocumentSourcePreview', () => ({ DocumentSourcePreview: ({ title, onClose }: { title: string; onClose: () => void }) => <div role="dialog" aria-label={title}><button onClick={onClose}>Close source comparison</button></div> }))
const row: ReviewedRow = { id: 401, digest: 'fictional', version_number: 1, facts: { source_account_identity_version_id: 100, disposition: 'include', event_type: 'purchase', signed_amount_cents: -1000, purchase_amount_cents: 1000, posted_on: '2026-09-15', merchant: 'Fictional purchase', budget_category_id: 10, overlap_disposition: 'canonical' }, reason: 'Reviewed', projection: { action: 'none' }, actual: null, source: { document_import_id: 1204, filename: 'Fictional canonical.pdf', locator: { page: 2 }, source_available: true } }
afterEach(cleanup)
beforeEach(() => { vi.mocked(fetchDocumentImport).mockReset() })
describe('canonical source comparison', () => {
  it('checks the exact source import before previewing and permits a fresh authorized retry', async () => {
    vi.mocked(fetchDocumentImport).mockRejectedValueOnce(new Error('Access removed')).mockResolvedValueOnce({ id: 1204, filename: 'Fictional canonical.pdf' } as Awaited<ReturnType<typeof fetchDocumentImport>>)
    render(<ReviewedSourcePreview row={row} disabled={false} />)
    fireEvent.click(screen.getByRole('button', { name: 'Preview source Fictional canonical.pdf' }))
    await screen.findByRole('alert'); expect(screen.queryByRole('dialog')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Preview source Fictional canonical.pdf' }))
    await screen.findByRole('dialog', { name: 'Preview Fictional canonical.pdf' })
    expect(fetchDocumentImport).toHaveBeenNthCalledWith(1,1204); expect(fetchDocumentImport).toHaveBeenNthCalledWith(2,1204)
  })
  it('does not render a late source response after its row unmounts', async () => {
    let resolve!: (value: Awaited<ReturnType<typeof fetchDocumentImport>>) => void
    vi.mocked(fetchDocumentImport).mockImplementation(() => new Promise((done) => { resolve = done }))
    const view = render(<ReviewedSourcePreview row={row} disabled={false} />)
    fireEvent.click(screen.getByRole('button', { name: 'Preview source Fictional canonical.pdf' })); view.unmount()
    resolve({ id: 1204, filename: 'Fictional canonical.pdf' } as Awaited<ReturnType<typeof fetchDocumentImport>>)
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull())
  })
})
