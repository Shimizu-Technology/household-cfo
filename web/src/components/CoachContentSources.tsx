import { useCallback, useEffect, useMemo, useRef, useState, type ChangeEvent, type FormEvent } from 'react'
import {
  ApiRequestError,
  acceptAdminContentSourceCandidate,
  deleteAdminContentSource,
  fetchAdminContentSource,
  fetchAdminContentSources,
  rejectAdminContentSourceCandidate,
  retryAdminContentSourceCleanups,
  reprocessAdminContentSource,
  updateAdminContentSourceCandidate,
  uploadAdminContentSource,
} from '../api'
import type {
  AdminContentItem,
  AdminContentItemKind,
  AdminContentScope,
  AdminContentSource,
  AdminContentSourceCandidate,
  CurrentUser,
} from '../api'
import { Button } from './Button'
import './CoachContentSources.css'

const kinds: AdminContentItemKind[] = ['guidance', 'script', 'example', 'phrase', 'culture', 'finance_reference']
const acceptedExtensions = ['pdf', 'docx', 'txt', 'md', 'vtt', 'srt']
const terminalStatuses = new Set(['upload_cleanup_failed', 'needs_review', 'failed', 'deletion_failed', 'source_deleted'])
const safetyCodes = new Set(['unsafe_instruction', 'personal_information', 'household_fact', 'regional_stereotype'])
const normalizeTitle = (value: string) => value.trim().replace(/\s+/g, ' ')

type CandidateDraft = { title: string; kind: AdminContentItemKind; content: string; topics: string }
type GuardedOpen = { type: 'source'; id: number } | { type: 'candidate'; id: number } | { type: 'delete' } | null

export function CoachContentSources({ currentUser, onDirtyChange, onItemAccepted, onReviewItem }: {
  currentUser: CurrentUser
  onDirtyChange: (dirty: boolean) => void
  onItemAccepted: (item: AdminContentItem) => void
  onReviewItem: (itemId: number) => void
}) {
  const [sources, setSources] = useState<AdminContentSource[]>([])
  const [selectedSource, setSelectedSource] = useState<AdminContentSource | null>(null)
  const [selectedCandidateId, setSelectedCandidateId] = useState<number | null>(null)
  const [draft, setDraft] = useState<CandidateDraft | null>(null)
  const [file, setFile] = useState<File | null>(null)
  const [scope, setScope] = useState<AdminContentScope>('coach')
  const [loading, setLoading] = useState(true)
  const [listReady, setListReady] = useState(false)
  const [listLoadFailed, setListLoadFailed] = useState(false)
  const [action, setAction] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [pendingOpen, setPendingOpen] = useState<GuardedOpen>(null)
  const [confirmReject, setConfirmReject] = useState(false)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const [conflictCandidate, setConflictCandidate] = useState<AdminContentSourceCandidate | null>(null)
  const requestSequence = useRef(0)
  const listRequestSequence = useRef(0)
  const actionRef = useRef<string | null>(null)
  const noticeRef = useRef<HTMLDivElement>(null)
  const errorRef = useRef<HTMLDivElement>(null)
  const guardRef = useRef<HTMLDivElement>(null)
  const conflictRef = useRef<HTMLDivElement>(null)
  const deleteConfirmRef = useRef<HTMLDivElement>(null)
  const rejectConfirmRef = useRef<HTMLSpanElement>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)
  const candidateContentRef = useRef<HTMLTextAreaElement>(null)

  const selectedCandidate = selectedSource?.candidates.find((candidate) => candidate.id === selectedCandidateId) ?? null
  const candidateReviewable = selectedSource?.status === 'needs_review' && selectedCandidate?.status === 'proposed'
  const candidateDirty = Boolean(selectedCandidate && draft && (
    normalizeTitle(draft.title) !== selectedCandidate.title ||
    draft.content.trim() !== selectedCandidate.content ||
    draft.kind !== selectedCandidate.kind ||
    parseTopics(draft.topics).join('\n') !== selectedCandidate.topics.join('\n')
  ))
  const dirty = Boolean(file || candidateDirty || action === 'upload')

  useEffect(() => onDirtyChange(dirty), [dirty, onDirtyChange])
  useEffect(() => () => onDirtyChange(false), [onDirtyChange])
  useEffect(() => { if (error) queueMicrotask(() => errorRef.current?.focus()) }, [error])
  useEffect(() => { if (pendingOpen) queueMicrotask(() => guardRef.current?.querySelector<HTMLButtonElement>('button')?.focus()) }, [pendingOpen])
  useEffect(() => { if (conflictCandidate) queueMicrotask(() => conflictRef.current?.querySelector<HTMLButtonElement>('button')?.focus()) }, [conflictCandidate])
  useEffect(() => { if (confirmDelete) queueMicrotask(() => deleteConfirmRef.current?.querySelector<HTMLButtonElement>('button:last-child')?.focus()) }, [confirmDelete])
  useEffect(() => { if (confirmReject) queueMicrotask(() => rejectConfirmRef.current?.querySelector<HTMLButtonElement>('button:last-child')?.focus()) }, [confirmReject])

  const loadSources = useCallback(async (preserveSelection = true) => {
    const sequence = ++listRequestSequence.current
    setLoading(true)
    setListLoadFailed(false)
    setError(null)
    try {
      const next = await fetchAdminContentSources()
      if (sequence !== listRequestSequence.current) return
      setSources(next)
      if (!preserveSelection) setSelectedSource(null)
    } catch (caught) {
      if (sequence !== listRequestSequence.current) return
      setListLoadFailed(true)
      setError(messageFor(caught, 'Private sources could not load.'))
    } finally {
      if (sequence === listRequestSequence.current) {
        setLoading(false)
        setListReady(true)
      }
    }
  }, [])

  useEffect(() => { queueMicrotask(() => void loadSources()) }, [loadSources])

  const chooseCandidate = useCallback((candidate: AdminContentSourceCandidate | null) => {
    setSelectedCandidateId(candidate?.id ?? null)
    setDraft(candidate ? draftFor(candidate) : null)
    setConfirmReject(false)
    setConflictCandidate(null)
    setPendingOpen(null)
  }, [])

  const openSource = useCallback(async (id: number) => {
    if (actionRef.current) return
    const sequence = ++requestSequence.current
    const actionName = `source:${id}`
    actionRef.current = actionName
    setAction(actionName)
    setError(null)
    setNotice(null)
    try {
      const source = await fetchAdminContentSource(id)
      if (sequence !== requestSequence.current) return
      setSelectedSource(source)
      setSources((current) => replaceSource(current, source))
      const first = source.candidates.find((candidate) => candidate.status === 'proposed') ?? source.candidates[0] ?? null
      chooseCandidate(first)
    } catch (caught) {
      if (sequence === requestSequence.current) setError(messageFor(caught, 'This source could not load.'))
    } finally {
      if (sequence === requestSequence.current && actionRef.current === actionName) {
        actionRef.current = null
        setAction(null)
      }
    }
  }, [chooseCandidate])

  const pollingSourceId = selectedSource?.id ?? null
  const pollingSourceStatus = selectedSource?.status ?? null
  useEffect(() => {
    if (!pollingSourceId || !pollingSourceStatus || !['queued', 'processing', 'deletion_pending'].includes(pollingSourceStatus)) return
    let cancelled = false
    let timer = 0
    const poll = async () => {
      try {
        const source = await fetchAdminContentSource(pollingSourceId)
        if (cancelled) return
        setSelectedSource(source)
        setSources((current) => replaceSource(current, source))
        if (selectedCandidateId === null && source.candidates.length > 0) {
          const first = source.candidates.find((candidate) => candidate.status === 'proposed') ?? source.candidates[0]
          setSelectedCandidateId(first.id)
          setDraft(draftFor(first))
        }
        if (terminalStatuses.has(source.status) && source.status !== pollingSourceStatus) {
          setNotice(statusNotice(source.status))
          queueMicrotask(() => noticeRef.current?.focus())
        } else if (!terminalStatuses.has(source.status)) timer = window.setTimeout(() => void poll(), 3000)
      } catch {
        if (!cancelled) timer = window.setTimeout(() => void poll(), 6000)
      }
    }
    timer = window.setTimeout(() => void poll(), 2000)
    return () => { cancelled = true; window.clearTimeout(timer) }
  }, [pollingSourceId, pollingSourceStatus, selectedCandidateId])

  function requestSource(id: number) {
    if (actionRef.current) return
    if (candidateDirty) setPendingOpen({ type: 'source', id })
    else void openSource(id)
  }

  function requestCandidate(candidate: AdminContentSourceCandidate) {
    if (actionRef.current) return
    if (candidateDirty) setPendingOpen({ type: 'candidate', id: candidate.id })
    else chooseCandidate(candidate)
  }

  function discardAndOpen() {
    const pending = pendingOpen
    setPendingOpen(null)
    if (!pending) return
    if (pending.type === 'delete') { chooseCandidate(selectedCandidate); setConfirmDelete(true); return }
    if (pending.type === 'source') void openSource(pending.id)
    else chooseCandidate(selectedSource?.candidates.find((candidate) => candidate.id === pending.id) ?? null)
  }

  function selectFile(event: ChangeEvent<HTMLInputElement>) {
    setError(null)
    setNotice(null)
    const next = event.target.files?.[0] ?? null
    if (!next) { setFile(null); return }
    const clientError = validateFile(next)
    if (clientError) {
      setError(clientError)
      event.target.value = ''
      setFile(null)
      return
    }
    setFile(next)
  }

  async function upload(event: FormEvent) {
    event.preventDefault()
    if (!file || !listReady || loading || actionRef.current) return
    listRequestSequence.current += 1
    const preserveEditor = candidateDirty
    const uploaded = await runAction('upload', async () => {
      const source = await uploadAdminContentSource(file, currentUser.is_admin ? scope : 'coach')
      setSources((current) => replaceSource(current, source))
      setFile(null)
      if (fileInputRef.current) fileInputRef.current.value = ''
      setNotice('Private upload complete. We are reading the source now.')
      if (!preserveEditor) {
        setSelectedSource(source)
        chooseCandidate(source.candidates.find((candidate) => candidate.status === 'proposed') ?? source.candidates[0] ?? null)
      }
    }, 'The source could not be uploaded.')
    if (uploaded) queueMicrotask(() => noticeRef.current?.focus())
  }

  async function retrySource() {
    if (!selectedSource) return
    await runAction(`retry:${selectedSource.id}`, async () => {
      const source = await reprocessAdminContentSource(selectedSource.id)
      setSelectedSource(source)
      setSources((current) => replaceSource(current, source))
      setNotice('Retry queued. You may keep working while the source is read.')
    })
  }

  async function saveCandidate() {
    if (!selectedSource || !selectedCandidate || !draft) return false
    let saved: AdminContentSourceCandidate | null = null
    const succeeded = await runAction(`save:${selectedCandidate.id}`, async () => {
      saved = await updateAdminContentSourceCandidate(selectedSource.id, selectedCandidate, {
        title: normalizeTitle(draft.title), kind: draft.kind, content: draft.content.trim(), topics: parseTopics(draft.topics),
      })
      updateCandidate(saved!)
      setConflictCandidate(null)
      setNotice('Candidate edits saved. It is still unavailable to Mia.')
    })
    return succeeded ? saved : null
  }

  async function acceptCandidate() {
    if (!selectedSource || !selectedCandidate) return
    let candidate = selectedCandidate
    if (candidateDirty) {
      const saved = await saveCandidate()
      if (!saved) return
      candidate = saved
    }
    await runAction(`accept:${candidate.id}`, async () => {
      const result = await acceptAdminContentSourceCandidate(selectedSource.id, candidate)
      updateCandidate(result.candidate)
      onItemAccepted(result.item)
      setNotice('Content draft created. It is not available to Mia yet. Approve the item, publish a pack, and publish the assistant before Mia can use it.')
      queueMicrotask(() => noticeRef.current?.focus())
    })
  }

  async function rejectCandidate() {
    if (!selectedSource || !selectedCandidate) return
    await runAction(`reject:${selectedCandidate.id}`, async () => {
      const candidate = await rejectAdminContentSourceCandidate(selectedSource.id, selectedCandidate)
      updateCandidate(candidate)
      setConfirmReject(false)
      setNotice('Candidate rejected. It will remain unavailable to Mia.')
    })
  }

  async function removeSource() {
    if (!selectedSource) return
    await runAction(`delete:${selectedSource.id}`, async () => {
      const source = await deleteAdminContentSource(selectedSource.id)
      setSelectedSource(source)
      setSources((current) => replaceSource(current, source))
      setConfirmDelete(false)
      setNotice('Private source deletion is in progress. Approved content keeps its audit provenance.')
    })
  }

  async function runAction(name: string, callback: () => Promise<void>, fallback = 'That source change could not be saved.') {
    if (actionRef.current) return false
    actionRef.current = name
    setAction(name)
    setError(null)
    setNotice(null)
    try {
      await callback()
      return true
    } catch (caught) {
      if (caught instanceof ApiRequestError && caught.status === 409 && isCandidate(caught.payload.candidate)) {
        setConflictCandidate(caught.payload.candidate)
      } else if (caught instanceof ApiRequestError && caught.status === 422 && safetyCodes.has(caught.code ?? '') && isCandidate(caught.payload.candidate)) {
        updateCandidate(caught.payload.candidate)
        setError(caught.message)
      } else {
        setError(messageFor(caught, fallback))
      }
      return false
    } finally {
      if (actionRef.current === name) {
        actionRef.current = null
        setAction(null)
      }
    }
  }

  function updateCandidate(candidate: AdminContentSourceCandidate) {
    setSelectedSource((current) => current ? { ...current, candidates: current.candidates.map((value) => value.id === candidate.id ? candidate : value) } : current)
    setSelectedCandidateId(candidate.id)
    setDraft(draftFor(candidate))
  }

  function adoptCandidateBase(candidate: AdminContentSourceCandidate) {
    setSelectedSource((current) => current ? { ...current, candidates: current.candidates.map((value) => value.id === candidate.id ? candidate : value) } : current)
    setSelectedCandidateId(candidate.id)
  }

  function reloadConflictCandidate() {
    if (!conflictCandidate) return
    updateCandidate(conflictCandidate)
    setConflictCandidate(null)
    setError(null)
    setNotice('The latest server version is loaded. Review it before continuing.')
  }

  const activeCount = useMemo(() => selectedSource?.candidates.filter((candidate) => candidate.status === 'proposed').length ?? 0, [selectedSource])
  const failedCleanupCount = useMemo(() => sources.filter((source) => source.status === 'upload_cleanup_failed').length, [sources])

  async function retryFailedUploadCleanups() {
    await runAction('cleanup-sweep', async () => {
      const count = await retryAdminContentSourceCleanups()
      setNotice(`${count} failed private upload cleanup ${count === 1 ? 'was' : 'were'} queued to retry.`)
      await loadSources()
    })
  }

  return (
    <article className="panel coach-source-intake" aria-labelledby="coach-source-title">
      <header className="coach-source-header">
        <div><p className="eyebrow">Bring in a source (optional)</p><h3 id="coach-source-title">Turn private material into reviewable drafts</h3><p>Upload text-based teaching material. Nothing becomes available to Mia automatically.</p></div>
        <ol className="coach-source-trust" aria-label="Content publication steps"><li>Private source</li><li>Review candidates</li><li>Content draft</li><li>Approve item</li><li>Publish pack</li><li>Publish assistant</li></ol>
      </header>

      {error && <div className="coach-source-alert is-error" role="alert" tabIndex={-1} ref={errorRef}><span>{error}</span>{listLoadFailed && <button type="button" onClick={() => void loadSources()}>Retry</button>}</div>}
      {conflictCandidate && <div className="coach-source-alert is-error" role="alert" tabIndex={-1} ref={conflictRef}><span>This candidate changed on the server. Your edits are still here.</span><button type="button" onClick={() => { adoptCandidateBase(conflictCandidate); setConflictCandidate(null); queueMicrotask(() => candidateContentRef.current?.focus()) }}>Keep editing</button><button type="button" onClick={reloadConflictCandidate}>Reload server candidate</button></div>}
      {notice && <div className="coach-source-alert is-success" role="status" tabIndex={-1} ref={noticeRef}><span>{notice}</span>{selectedCandidate?.accepted_content_item_id && <button type="button" onClick={() => onReviewItem(selectedCandidate.accepted_content_item_id!)}>Review content draft</button>}</div>}

      <form className="coach-source-upload" onSubmit={(event) => void upload(event)}>
        <label htmlFor="coach-source-file"><span>Private source file</span><input ref={fileInputRef} id="coach-source-file" type="file" accept=".pdf,.docx,.txt,.md,.vtt,.srt" onChange={selectFile} aria-describedby="coach-source-file-help" disabled={!listReady || loading || Boolean(action)} /></label>
        {currentUser.is_admin && <label><span>Owner</span><select value={scope} disabled={!listReady || loading || Boolean(action)} onChange={(event) => setScope(event.target.value as AdminContentScope)}><option value="platform">Platform library</option><option value="coach">My coaching library</option></select></label>}
        <Button type="submit" disabled={!file || !listReady || loading || Boolean(action)}>{action === 'upload' ? 'Uploading privately…' : 'Upload and read'}</Button>
        <p id="coach-source-file-help">PDF (12 MB), DOCX (10 MB), or TXT, MD, VTT, SRT (2 MB). Text PDFs only; scanned pages need OCR first. The file is stored privately. Extracted text is sent through the configured AI provider's no-data-collection routing setting to propose drafts. It never reaches participant chat until you approve an item, publish a pack, and publish the assistant.</p>
        <details className="coach-source-limits"><summary>Library and upload limits</summary><p>Each staff account may keep up to 100 active private sources totaling 512 MB, with 5 uploads in progress and 10 new uploads started per 15 minutes.</p></details>
        {file && <p className="coach-source-file-name"><strong>Ready:</strong> {file.name} · {formatBytes(file.size)}</p>}
      </form>

      {currentUser.is_admin && failedCleanupCount > 0 && <div className="coach-source-alert is-error" role="alert"><span>{failedCleanupCount} abandoned private upload {failedCleanupCount === 1 ? 'needs' : 'need'} storage cleanup.</span><button type="button" disabled={Boolean(action)} onClick={() => void retryFailedUploadCleanups()}>Retry failed cleanup</button></div>}

      <div className="coach-source-workspace">
        <section className="coach-source-list" aria-label="Private content sources">
          <header><h4>Private sources</h4><small>Showing {sources.length} current</small></header>
          {loading && sources.length === 0 && <p role="status">Loading private sources…</p>}
          {!loading && sources.length === 0 && !error && <p>No private sources yet. Manual content creation below is always available.</p>}
          {sources.map((source) => <button type="button" key={source.id} aria-current={selectedSource?.id === source.id ? 'true' : undefined} className={selectedSource?.id === source.id ? 'is-selected' : ''} onClick={() => requestSource(source.id)} disabled={Boolean(action)}><span><strong>{source.filename}</strong><small>{formatBytes(source.byte_size)}</small></span><span className={`coach-source-status is-${source.status}`}>{statusLabel(source.status)}</span></button>)}
        </section>

        <section className="coach-source-detail" aria-label="Selected source details">
          {!selectedSource && <p>Select a source to review its status and candidates.</p>}
          {selectedSource && <>
            <header><div><h4>{selectedSource.filename}</h4><p><span className={`coach-source-status is-${selectedSource.status}`}>{statusLabel(selectedSource.status)}</span> · {activeCount} candidate{activeCount === 1 ? '' : 's'} waiting</p></div><div className="coach-source-detail-actions">{selectedSource.status === 'failed' && <Button size="compact" variant="secondary" disabled={Boolean(action)} onClick={() => void retrySource()}>Retry reading</Button>}{selectedSource.status === 'deletion_failed' && <Button size="compact" variant="secondary" disabled={Boolean(action)} onClick={() => void removeSource()}>Retry private-file deletion</Button>}{selectedSource.source_available && !confirmDelete && <Button id="coach-source-delete-trigger" size="compact" variant="ghost" disabled={Boolean(action)} onClick={() => candidateDirty ? setPendingOpen({ type: 'delete' }) : setConfirmDelete(true)}>Delete source</Button>}</div></header>
            {confirmDelete && <div className="coach-source-confirm" role="alert" tabIndex={-1} ref={deleteConfirmRef}><p>Delete the private file? Redacted evidence excerpts and review records remain with approved content provenance.</p><div><Button size="compact" variant="danger" onClick={() => void removeSource()} disabled={Boolean(action)}>Delete private file</Button><Button size="compact" variant="ghost" onClick={() => { setConfirmDelete(false); queueMicrotask(() => document.getElementById('coach-source-delete-trigger')?.focus()) }}>Keep source</Button></div></div>}
            {selectedSource.error && <p className="coach-source-alert is-error" role="alert">{selectedSource.error}</p>}
            {['queued', 'processing'].includes(selectedSource.status) && <p role="status">{selectedSource.status === 'queued' ? 'Queued to read. You may leave this page.' : 'Reading and proposing candidates. You may keep working.'}</p>}
            {selectedSource.status === 'needs_review' && selectedSource.candidates.length === 0 && <p>No safe, general coaching candidates were found. The private source remains unavailable to Mia.</p>}
            {selectedSource.candidates.length > 0 && <div className="coach-candidate-workspace">
              <div className="coach-candidate-list" aria-label="Source candidates">{selectedSource.candidates.map((candidate) => <button type="button" key={candidate.id} aria-current={selectedCandidateId === candidate.id ? 'true' : undefined} className={selectedCandidateId === candidate.id ? 'is-selected' : ''} onClick={() => requestCandidate(candidate)} disabled={Boolean(action)}><span><strong>{candidate.title}</strong><small>{label(candidate.kind)}</small></span><small>{label(candidate.status)}</small></button>)}</div>
              {selectedCandidate && draft && <form className="coach-candidate-editor" onSubmit={(event) => { event.preventDefault(); void saveCandidate() }}>
                <label><span>Candidate title</span><input maxLength={160} disabled={!candidateReviewable || Boolean(action)} value={draft.title} onChange={(event) => setDraft({ ...draft, title: event.target.value })} /></label>
                <label><span>Type</span><select disabled={!candidateReviewable || Boolean(action)} value={draft.kind} onChange={(event) => setDraft({ ...draft, kind: event.target.value as AdminContentItemKind })}>{kinds.map((kind) => <option key={kind} value={kind}>{label(kind)}</option>)}</select></label>
                <label><span>Draft wording</span><textarea ref={candidateContentRef} rows={7} maxLength={10000} disabled={!candidateReviewable || Boolean(action)} value={draft.content} onChange={(event) => setDraft({ ...draft, content: event.target.value })} /><small>{draft.content.length.toLocaleString()} / 10,000 characters</small></label>
                <label><span>Suggested topics</span><input disabled={!candidateReviewable || Boolean(action)} value={draft.topics} onChange={(event) => setDraft({ ...draft, topics: event.target.value })} /><small>Comma separated review metadata; Mia does not use these labels directly.</small></label>
                <figure className="coach-candidate-evidence"><figcaption>Source evidence · {locatorLabel(selectedCandidate.evidence_locator)}</figcaption><blockquote>{selectedCandidate.evidence_excerpt}</blockquote></figure>
                {selectedCandidate.safety_code && selectedCandidate.safety_code !== 'source_deleted' && <p className="coach-source-safety" role="note">Needs attention: {safetyLabel(selectedCandidate.safety_code)} Edit the candidate, then save to run the server check again.</p>}
                {selectedCandidate.safety_code === 'source_deleted' && <p className="coach-content-note">The private source file was deleted. This review record remains for audit history.</p>}
                {candidateReviewable && <div className="coach-candidate-actions"><Button type="submit" variant="secondary" disabled={!candidateDirty || Boolean(action) || !draft.title.trim() || !draft.content.trim()}>Save edits</Button><Button type="button" disabled={Boolean(action) || !draft.title.trim() || !draft.content.trim() || Boolean(selectedCandidate.safety_code && !candidateDirty)} onClick={() => void acceptCandidate()}>{candidateDirty ? (selectedCandidate.safety_code ? 'Save, recheck, and create draft' : 'Save and create draft') : 'Create content draft'}</Button>{!confirmReject ? <Button id="coach-source-reject-trigger" type="button" variant="ghost" disabled={Boolean(action)} onClick={() => setConfirmReject(true)}>Reject</Button> : <span className="coach-inline-confirm" role="alert" tabIndex={-1} ref={rejectConfirmRef}>Reject this candidate?<button type="button" onClick={() => void rejectCandidate()}>Yes, reject</button><button type="button" onClick={() => { setConfirmReject(false); queueMicrotask(() => document.getElementById('coach-source-reject-trigger')?.focus()) }}>Cancel</button></span>}</div>}
                {selectedCandidate.status === 'proposed' && !candidateReviewable && <p className="coach-content-note">Candidate review is paused while the source changes state.</p>}
                {selectedCandidate.status === 'accepted' && <p className="coach-source-alert is-success">Content draft created. It remains unavailable until item approval, pack publication, and assistant publication.</p>}
              </form>}
            </div>}
          </>}
        </section>
      </div>

      {pendingOpen && <div className="coach-source-guard" role="alert" tabIndex={-1} ref={guardRef}><p>You have unsaved candidate edits.</p><Button size="compact" onClick={() => { setPendingOpen(null); queueMicrotask(() => candidateContentRef.current?.focus()) }}>Keep editing</Button><Button size="compact" variant="secondary" onClick={discardAndOpen}>Discard and open</Button></div>}
    </article>
  )
}

function replaceSource(sources: AdminContentSource[], source: AdminContentSource) {
  const next = sources.filter((value) => value.id !== source.id)
  if (source.status === 'source_deleted') return next.sort((left, right) => right.id - left.id)
  return [source, ...next].sort((left, right) => right.id - left.id)
}

function draftFor(candidate: AdminContentSourceCandidate): CandidateDraft {
  return { title: candidate.title, kind: candidate.kind, content: candidate.content, topics: candidate.topics.join(', ') }
}

function parseTopics(value: string) {
  return Array.from(new Set(value.split(',').map((topic) => topic.trim()).filter(Boolean))).slice(0, 12)
}

function validateFile(file: File) {
  const extension = file.name.split('.').pop()?.toLowerCase() ?? ''
  if (!acceptedExtensions.includes(extension)) return 'Choose a PDF, DOCX, TXT, MD, VTT, or SRT file.'
  if (file.size === 0) return 'Choose a source file that contains text. Empty files cannot be read.'
  const limit = extension === 'pdf' ? 12 * 1024 * 1024 : extension === 'docx' ? 10 * 1024 * 1024 : 2 * 1024 * 1024
  if (file.size > limit) return `${extension.toUpperCase()} files must be ${formatBytes(limit)} or smaller. The source was not truncated.`
  return null
}

function statusLabel(status: AdminContentSource['status']) {
  return ({ upload_cleanup_failed: 'Upload cleanup needs admin retry', queued: 'Queued', processing: 'Reading source', needs_review: 'Ready for review', failed: 'Needs attention', deletion_pending: 'Deleting private file', deletion_failed: 'Deletion needs retry', source_deleted: 'Private file deleted' } as const)[status]
}

function statusNotice(status: AdminContentSource['status']) {
  return ({
    upload_cleanup_failed: 'Private upload cleanup needs an administrator to retry it.',
    needs_review: 'Source ready for review. Its candidates remain unavailable to Mia until publication is complete.',
    failed: 'The source needs attention. Review the safe error below before trying again.',
    deletion_failed: 'Private-file deletion needs a retry. The source remains unavailable.',
    source_deleted: 'The private source file was deleted. Approved provenance and redacted review records remain.',
  } as Partial<Record<AdminContentSource['status'], string>>)[status] ?? statusLabel(status)
}

function isCandidate(value: unknown): value is AdminContentSourceCandidate {
  if (!value || typeof value !== 'object') return false
  const candidate = value as Partial<AdminContentSourceCandidate>
  return typeof candidate.id === 'number' && typeof candidate.revision === 'number' && typeof candidate.digest === 'string'
}

function safetyLabel(code: string) {
  return ({ unsafe_instruction: 'unsafe override instructions were found.', personal_information: 'personal or identifying information was found.', household_fact: 'household-specific facts were found.', regional_stereotype: 'a regional or cultural assumption was found.' } as Record<string, string>)[code] ?? 'the candidate did not pass the content safety check.'
}

function locatorLabel(locator: Record<string, string | number>) {
  return Object.entries(locator).filter(([key]) => key !== 'excerpt_digest').map(([key, value]) => `${label(key)} ${value}`).join(' · ') || 'Location recorded'
}

function formatBytes(bytes: number) {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${Math.ceil(bytes / 1024)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(bytes % (1024 * 1024) === 0 ? 0 : 1)} MB`
}

function label(value: string) { return value.replaceAll('_', ' ').replace(/^./, (letter) => letter.toUpperCase()) }

function messageFor(caught: unknown, fallback: string) {
  if (caught instanceof ApiRequestError || caught instanceof Error) return caught.message || fallback
  return fallback
}
