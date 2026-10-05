import { useEffect, useRef, useState } from 'react'
import { fetchDocumentImport, fetchDocumentImportSourceContent, fetchDocumentImportSourcePreview, fetchDocumentImportSourceUrl, type FinancialDocumentImport } from '../api'
import type { ReviewedRow } from '../lib/participantSourceReview'
import { DocumentSourcePreview } from './DocumentSourcePreview'
export function ReviewedSourcePreview({ row, disabled }: { row: ReviewedRow; disabled: boolean }) {
  const [document, setDocument] = useState<FinancialDocumentImport | null>(null)
  const [loading, setLoading] = useState(false); const [error, setError] = useState<string | null>(null)
  const epoch = useRef(0)
  useEffect(() => () => { epoch.current += 1 }, [])
  async function open() {
    if (!row.source?.document_import_id || loading) return
    const request = ++epoch.current; setLoading(true); setError(null)
    try { const source = await fetchDocumentImport(row.source.document_import_id); if (request === epoch.current) { setDocument(source); setLoading(false) } }
    catch (failure) { if (request === epoch.current) { setError(failure instanceof Error ? failure.message : 'Original source unavailable.'); setLoading(false) } }
  }
  return <><button type="button" disabled={disabled || loading || !row.source?.source_available || !row.source.document_import_id} onClick={() => { void open() }}>{loading ? 'Checking original source…' : `Preview source ${row.source?.filename ?? 'original'}`}</button>{error && <p role="alert">{error}</p>}{document && <DocumentSourcePreview documentImport={document} title={`Preview ${document.filename}`} description="Compare the original source with this exact reviewed row. Preview does not approve a match or financial change." onClose={() => { epoch.current += 1; setDocument(null) }} onFetchSourceUrl={fetchDocumentImportSourceUrl} onFetchSourcePreview={fetchDocumentImportSourcePreview} onFetchSourceContent={fetchDocumentImportSourceContent} />}</>
}
