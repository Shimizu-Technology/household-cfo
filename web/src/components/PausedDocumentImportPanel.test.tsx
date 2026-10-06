// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, test, vi } from 'vitest'
import type { FinancialDocumentImport } from '../api'
import { PausedDocumentImportPanel } from './PausedDocumentImportPanel'
afterEach(cleanup)
const snapshot = { id: 3, filename: 'earlier-qa-budget.pdf', document_kind: 'statement', context_paused_by_restart: true, source_available: true, extracted_summary: 'Earlier extraction summary.', items: [{ id: 7, label: 'Earlier salary', amount: 0, balance: null, payment: null, evidence: 'Source row' }], transaction_drafts: [{ id: 11, merchant: 'Earlier grocery', occurred_on: '2026-10-01', amount: 20, status: 'confirmed' }] } as FinancialDocumentImport
function props() { return { documentImport: snapshot, uploading: false, opening: false, removing: false, acceptedFileTypes: '.pdf', onOpenSource: vi.fn(), onDeleteSource: vi.fn(), onUpload: vi.fn() } }
test('earlier snapshot is explicitly historical and provides no apply, edit, reprocess or transaction approval actions', () => {
  render(<PausedDocumentImportPanel {...props()} />)
  expect(screen.getByText('Previous financial picture')).toBeTruthy()
  expect(screen.getByText('Amount: $0.00')).toBeTruthy()
  expect(screen.getByText('Earlier grocery')).toBeTruthy()
  expect(screen.queryByRole('button', { name: /Apply|Edit|Reprocess|Confirm|Ignore|Match/ })).toBeNull()
  expect(screen.queryByRole('textbox')).toBeNull()
})
test('original preview and removal are separate from explicitly choosing a new file review', () => {
  const p = props(); render(<PausedDocumentImportPanel {...p} />)
  fireEvent.click(screen.getByRole('button', { name: 'Preview earlier original' }))
  fireEvent.click(screen.getByRole('button', { name: 'Remove earlier original' }))
  expect(p.onOpenSource).toHaveBeenCalledOnce(); expect(p.onDeleteSource).toHaveBeenCalledOnce(); expect(p.onUpload).not.toHaveBeenCalled()
  const file = new File(['fictional'], 'fresh-copy.pdf', { type: 'application/pdf' })
  fireEvent.change(screen.getByLabelText('Choose a fresh copy'), { target: { files: [file] } })
  expect(p.onUpload).toHaveBeenCalledWith(file)
})
test('retained extraction remains readable when its raw source has been removed', () => {
  const p = props(); render(<PausedDocumentImportPanel {...p} documentImport={{ ...snapshot, source_available: false }} />)
  expect(screen.getByRole('button', { name: 'Preview earlier original' })).toHaveProperty('disabled', true)
  expect(screen.getByRole('button', { name: 'Remove earlier original' })).toHaveProperty('disabled', true)
  expect(screen.getByText('Earlier extraction summary.')).toBeTruthy()
  expect(screen.getByLabelText('Choose a fresh copy')).toHaveProperty('disabled', false)
})
