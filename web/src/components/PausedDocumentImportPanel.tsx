import { formatReviewMoney } from '../lib/reviewMoney'
import { formatDay } from '../lib/plainDates'
import { useState } from 'react'
import type { FinancialDocumentImport } from '../api'
import './PausedDocumentImportPanel.css'

/** Earlier extraction snapshots remain readable, without any current-picture mutations. */
type PanelProps = {
  documentImport: FinancialDocumentImport; uploading: boolean; opening: boolean; removing: boolean; acceptedFileTypes: string;
  onOpenSource: () => void; onDeleteSource: () => void; onUpload: (file: File) => Promise<boolean> | void
}
export function PausedDocumentImportPanel(props: PanelProps) {
  return <PausedDocumentImportContent key={props.documentImport.id} {...props} />
}
function PausedDocumentImportContent({ documentImport, uploading, opening, removing, acceptedFileTypes, onOpenSource, onDeleteSource, onUpload }: PanelProps) {
  const [retryFile, setRetryFile] = useState<File | null>(null)
  async function upload(file: File) {
    setRetryFile(file)
    if (await onUpload(file)) setRetryFile(current => current === file ? null : current)
  }
  const inputId = `document-fresh-copy-${documentImport.id}`
  return <article className="document-review-panel document-paused-panel" aria-label={`Earlier file ${documentImport.filename}`}>
    <header><span className="document-status">Previous financial picture</span><h4>{documentImport.filename}</h4><p>This file was uploaded before you started over. Its extracted information is retained as history and does not supply your new plan or Mia context.</p></header>
    <section className="document-paused-review" aria-label="Fresh document review"><h5>Use this file in your new picture?</h5><p>Choose a fresh copy to create a new review. Check the extracted facts before applying them. This earlier snapshot cannot be edited, reprocessed or applied again.</p>
      <div className="document-paused-actions"><button type="button" className="secondary-button" disabled={!documentImport.source_available || opening} onClick={onOpenSource}>{opening ? 'Opening' : 'Preview earlier original'}</button>
        <input id={inputId} className="sr-only" type="file" accept={acceptedFileTypes} disabled={uploading} onChange={event => { const file = event.currentTarget.files?.[0]; if (file) void upload(file); event.currentTarget.value = '' }} />
        <label className="document-empty-upload-button" htmlFor={inputId} aria-disabled={uploading}>{uploading ? 'Uploading privately' : 'Choose a fresh copy'}</label>
        <button type="button" className="secondary-button" disabled={!documentImport.source_available || removing} onClick={onDeleteSource}>{removing ? 'Removing' : 'Remove earlier original'}</button>
      </div>
      {retryFile && !uploading && <div className="form-stack document-upload-recovery"><p style={{ overflowWrap: 'anywhere' }}>{retryFile.name} is still selected.</p><button type="button" className="secondary-button" onClick={() => void upload(retryFile)}>Try this file again</button></div>}
      <p>Removing the original keeps this earlier extraction history. It does not apply any earlier values to your new picture.</p>
      {!documentImport.source_available && <p>The original file is no longer available. Your earlier extraction history remains below.</p>}
    </section>
    <details className="document-paused-history"><summary>View earlier extracted information</summary>
      {documentImport.extracted_summary && <p>{documentImport.extracted_summary}</p>}
      {documentImport.items.length > 0 && <ul aria-label="Earlier extracted values">{documentImport.items.map(item => <li key={item.id}><strong>{item.label}</strong><span>{[['Amount', item.amount], ['Balance', item.balance], ['Payment', item.payment]].filter(([, value]) => typeof value === 'number').map(([label, value]) => `${label}: ${formatReviewMoney(Math.round((value as number) * 100))}`).join(' · ') || 'Amount not entered'}</span>{item.evidence && <small>{item.evidence}</small>}</li>)}</ul>}
      {documentImport.transaction_drafts.length > 0 && <ul aria-label="Earlier extracted transactions">{documentImport.transaction_drafts.map(draft => <li key={draft.id}><strong>{draft.merchant}</strong><span>{formatDay(draft.occurred_on, { year: true })} · {formatReviewMoney(Math.round((draft.amount) * 100))} · Earlier {draft.status.replaceAll('_', ' ')}</span></li>)}</ul>}
      {documentImport.items.length === 0 && documentImport.transaction_drafts.length === 0 && <p>No earlier extracted rows are available.</p>}
    </details>
  </article>
}
