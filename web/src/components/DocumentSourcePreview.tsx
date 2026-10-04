import { useCallback, useEffect, useRef, useState } from 'react'
import type { DocumentSourcePreview as SourcePreviewData, DocumentSourceUrl, FinancialDocumentImport } from '../api'
import { usePilotDialog } from '../lib/usePilotDialog'
import './DocumentSourcePreview.css'

const ACCESS_RECHECK_INTERVAL_MS = 30_000
const IMAGE_TYPES = ['image/jpeg', 'image/png', 'image/webp']

export function DocumentSourcePreview({ documentImport, title, description, onClose, onFetchSourceUrl, onFetchSourcePreview, onFetchSourceContent }: {
  documentImport: FinancialDocumentImport
  title: string
  description: string
  onClose: () => void
  onFetchSourceUrl: (id: number, signal?: AbortSignal) => Promise<DocumentSourceUrl>
  onFetchSourcePreview: (id: number, signal?: AbortSignal) => Promise<SourcePreviewData>
  onFetchSourceContent: (id: number, download?: boolean, signal?: AbortSignal) => Promise<Blob>
}) {
  const [source, setSource] = useState<DocumentSourceUrl | null>(null)
  const [preview, setPreview] = useState<SourcePreviewData | null>(null)
  const [imageUrl, setImageUrl] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [operation, setOperation] = useState<'pdf' | 'download' | null>(null)
  const [error, setError] = useState<string | null>(null)
  const mounted = useRef(false)
  const epoch = useRef(0)
  const checking = useRef<number | null>(null)
  const operationBusy = useRef<number | null>(null)
  const controllers = useRef(new Set<AbortController>())
  const urls = useRef(new Set<string>())
  const imageUrlRef = useRef<string | null>(null)
  const imageIdentityRef = useRef<string | null>(null)
  const pendingPopup = useRef<Window | null>(null)
  const downloadTimers = useRef(new Set<ReturnType<typeof setTimeout>>())

  const releaseResources = useCallback(() => {
    epoch.current += 1
    checking.current = null
    operationBusy.current = null
    for (const controller of controllers.current) controller.abort()
    controllers.current.clear()
    for (const url of urls.current) URL.revokeObjectURL(url)
    urls.current.clear()
    imageUrlRef.current = null
    imageIdentityRef.current = null
    for (const timer of downloadTimers.current) clearTimeout(timer)
    downloadTimers.current.clear()
    pendingPopup.current?.close()
    pendingPopup.current = null
  }, [])

  const clearFailedRead = useCallback((failure: unknown) => {
    releaseResources()
    setSource(null)
    setPreview(null)
    setImageUrl(null)
    setOperation(null)
    setLoading(false)
    setError(failure instanceof Error ? failure.message : 'Private source access could not be confirmed. Try again.')
  }, [releaseResources])

  const close = useCallback(() => {
    mounted.current = false
    releaseResources()
    onClose()
  }, [onClose, releaseResources])
  const dialogRef = usePilotDialog(close)

  const recheckAccess = useCallback(async () => {
    if (!mounted.current || checking.current !== null) return
    const requestEpoch = epoch.current
    checking.current = requestEpoch
    const live = () => mounted.current && requestEpoch === epoch.current
    const controller = new AbortController()
    controllers.current.add(controller)
    setLoading(true)
    setError(null)
    try {
      const metadata = await onFetchSourceUrl(documentImport.id, controller.signal)
      if (!live()) return
      if (metadata.authenticated_content !== true) throw new Error('This source requires an authenticated preview. Refresh the app before opening it.')
      let nextPreview: SourcePreviewData | null = null
      let nextImageUrl: string | null = null
      let nextImageIdentity: string | null = null
      if (usesServerPreview(metadata.filename, metadata.content_type)) {
        nextPreview = await onFetchSourcePreview(documentImport.id, controller.signal)
        if (!live()) return
      } else if (metadata.inline_supported && IMAGE_TYPES.includes(metadata.content_type.toLowerCase())) {
        nextImageIdentity = metadata.source_version ? JSON.stringify([documentImport.id, metadata.source_version, metadata.filename, metadata.content_type]) : null
        if (nextImageIdentity && nextImageIdentity === imageIdentityRef.current && imageUrlRef.current) {
          nextImageUrl = imageUrlRef.current
        } else {
          const blob = await onFetchSourceContent(documentImport.id, false, controller.signal)
          if (!live()) return
          if (blob.type.toLowerCase() !== metadata.content_type.toLowerCase()) throw new Error('The source returned an unexpected image type. Retry the private preview or contact support.')
          nextImageUrl = URL.createObjectURL(blob)
          urls.current.add(nextImageUrl)
        }
      }
      if (!live()) return
      if (imageUrlRef.current && imageUrlRef.current !== nextImageUrl) {
        URL.revokeObjectURL(imageUrlRef.current)
        urls.current.delete(imageUrlRef.current)
      }
      imageUrlRef.current = nextImageUrl
      imageIdentityRef.current = nextImageIdentity
      setImageUrl(nextImageUrl)
      setSource(metadata)
      setPreview(nextPreview)
    } catch (failure) {
      if (live()) clearFailedRead(failure)
    } finally {
      controllers.current.delete(controller)
      if (checking.current === requestEpoch) checking.current = null
      if (live()) setLoading(false)
    }
  }, [clearFailedRead, documentImport.id, onFetchSourceContent, onFetchSourcePreview, onFetchSourceUrl])

  useEffect(() => {
    mounted.current = true
    queueMicrotask(() => { if (mounted.current) void recheckAccess() })
    const onFocus = () => { void recheckAccess() }
    const onVisibility = () => { if (!document.hidden) void recheckAccess() }
    const interval = setInterval(() => { if (!document.hidden) void recheckAccess() }, ACCESS_RECHECK_INTERVAL_MS)
    window.addEventListener('focus', onFocus)
    document.addEventListener('visibilitychange', onVisibility)
    return () => {
      mounted.current = false
      clearInterval(interval)
      window.removeEventListener('focus', onFocus)
      document.removeEventListener('visibilitychange', onVisibility)
      releaseResources()
    }
  }, [recheckAccess, releaseResources])

  async function readContent(download: boolean) {
    if (!source || loading || operationBusy.current !== null) return
    const requestEpoch = epoch.current
    operationBusy.current = requestEpoch
    const live = () => mounted.current && requestEpoch === epoch.current
    const controller = new AbortController()
    controllers.current.add(controller)
    setOperation(download ? 'download' : 'pdf')
    setError(null)
    try {
      if (!download) {
        // Preserve the browser's user gesture while authorized bytes are read.
        const popup = window.open('', '_blank')
        if (!popup) throw new Error('The browser blocked the new tab. Allow pop-ups for this app and try again.')
        popup.opener = null
        popup.document.title = 'Loading private PDF'
        pendingPopup.current = popup
      }
      const blob = await onFetchSourceContent(documentImport.id, download, controller.signal)
      if (!live()) return
      if (!download && blob.type.toLowerCase() !== 'application/pdf') throw new Error('The source returned an unexpected PDF type. Retry the private preview or contact support.')
      const url = URL.createObjectURL(blob)
      urls.current.add(url)
      if (download) {
        const anchor = document.createElement('a')
        anchor.href = url
        anchor.download = source.filename
        anchor.rel = 'noopener'
        document.body.append(anchor)
        anchor.click()
        anchor.remove()
        // Let browsers begin the download before releasing its temporary URL.
        const timer = setTimeout(() => {
          URL.revokeObjectURL(url)
          urls.current.delete(url)
          downloadTimers.current.delete(timer)
        }, 3_000)
        downloadTimers.current.add(timer)
      } else {
        pendingPopup.current?.location.replace(url)
        pendingPopup.current = null
      }
    } catch (failure) {
      if (live()) clearFailedRead(failure)
    } finally {
      controllers.current.delete(controller)
      if (operationBusy.current === requestEpoch) operationBusy.current = null
      if (live()) setOperation(null)
    }
  }

  const filename = source?.filename ?? documentImport.filename
  const isPdf = source?.inline_supported && source.content_type === 'application/pdf'
  const serverPreviewType = source && usesServerPreview(source.filename, source.content_type)
  return (
    <div className="document-preview-overlay" role="presentation">
      <button type="button" className="document-preview-backdrop" aria-label="Close document preview" onClick={close} />
      <section ref={dialogRef} className="document-preview-modal" role="dialog" aria-modal="true" aria-label={`Preview ${title}`} tabIndex={-1}>
        <header className="document-preview-header">
          <div><span className="document-status blue">Private preview</span><h3>{title}</h3><p>{description} · Every source read rechecks your access.</p></div>
          <div className="document-preview-actions">
            {source && <button type="button" disabled={loading || operation !== null} onClick={() => void readContent(true)}>{operation === 'download' ? 'Downloading' : 'Download source'}</button>}
            <button type="button" onClick={close}>Close</button>
          </div>
        </header>
        <div className="document-preview-body">
          {loading && <div className="document-preview-state" role="status">Checking private source access…</div>}
          {error && <div className="document-preview-state error" role="alert"><p>{error}</p><button type="button" onClick={() => void recheckAccess()}>Retry private preview</button></div>}
          {source && !loading && !error && <>
            {isPdf && <div className="document-preview-state document-pdf-handoff"><h4>Open this PDF in a separate browser tab</h4><p>The PDF opens after a fresh authenticated read. Keyboard focus and Close controls stay available here.</p><button type="button" disabled={operation !== null} onClick={() => void readContent(false)}>{operation === 'pdf' ? 'Opening PDF' : 'Open PDF in new tab'}</button></div>}
            {imageUrl && <img src={imageUrl} alt={filename} />}
            {preview?.type === 'spreadsheet' && <SpreadsheetSourcePreview preview={preview} />}
            {preview?.type === 'text' && <div className="document-text-preview"><pre>{preview.text || 'No text could be shown for this document.'}</pre></div>}
            {!isPdf && !imageUrl && !serverPreviewType && <div className="document-preview-state"><h4>Preview not available for this file type</h4><p>Use Download source to save the file after an authenticated read.</p></div>}
          </>}
          <p className="document-retention-help">Closing this preview releases temporary app URLs. Files already opened or downloaded may remain available in separate tabs or on your device.</p>
        </div>
      </section>
    </div>
  )
}

function SpreadsheetSourcePreview({ preview }: { preview: SourcePreviewData }) {
  const sheets = preview.sheets ?? []
  if (sheets.length === 0) return <div className="document-preview-state"><h4>No rows to preview</h4><p>No populated spreadsheet rows were found.</p></div>
  return <div className="document-spreadsheet-preview">{sheets.map((sheet) => <section className="document-preview-sheet" key={sheet.name}><div className="document-preview-sheet-heading"><strong>{sheet.name}</strong><span>{sheet.sampled_row_count} of {sheet.row_count} rows shown</span></div><div className="document-preview-table-wrap"><table><tbody>{sheet.rows.map((row) => <tr key={row.row}><th scope="row">{row.row}</th>{row.values.map((value, index) => <td key={`${row.row}-${index}`}>{value}</td>)}</tr>)}</tbody></table></div></section>)}</div>
}

function usesServerPreview(filename: string, contentType: string) {
  const name = filename.toLowerCase()
  return name.endsWith('.csv') || name.endsWith('.xls') || name.endsWith('.xlsx') || name.endsWith('.docx') || ['text/csv', 'text/plain', 'application/csv', 'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'].includes(contentType)
}
