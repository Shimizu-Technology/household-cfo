import { useEffect, useState } from 'react'
import { fetchEarlierMiaMessages, type EarlierMiaMessages } from '../api'
import { usePilotDialog } from '../lib/usePilotDialog'
import './EarlierMiaConversations.css'

export function EarlierMiaConversations({ onClose }: { onClose: () => void }) {
  const ref = usePilotDialog(onClose)
  const [page, setPage] = useState<EarlierMiaMessages | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [attempt, setAttempt] = useState(0)
  const [before, setBefore] = useState<number | undefined>()
  useEffect(() => {
    const controller = new AbortController()
    let active = true
    void fetchEarlierMiaMessages(before, controller.signal).then(result => {
      if (!active) return
      setPage(current => before && current ? { ...result, messages: [...result.messages, ...current.messages] } : result)
      setError(null)
    }).catch(caught => {
      if (active) setError(caught instanceof Error ? caught.message : 'Earlier conversations could not be loaded.')
    }).finally(() => { if (active) setLoading(false) })
    return () => { active = false; controller.abort() }
  }, [before, attempt])
  return <div className="pilot-dialog-overlay" role="presentation"><section ref={ref} className="pilot-dialog earlier-mia-dialog" role="dialog" aria-modal="true" aria-labelledby="earlier-mia-title" tabIndex={-1}>
    <header><div><p className="eyebrow">Private history</p><h2 id="earlier-mia-title">Earlier conversations</h2></div><button type="button" className="secondary-button" onClick={onClose}>Close</button></header>
    <div className="pilot-dialog-body">
      <p>These messages are from before your financial picture was reset. They are read-only and do not supply your current numbers or Mia’s coaching context.</p>
      {error && <p role="alert">{error}</p>}
      {error && <button type="button" className="secondary-button" disabled={loading} onClick={() => { setLoading(true); setAttempt(value => value + 1) }}>Try again</button>}
      {loading && <p role="status">Loading earlier conversations…</p>}
      {!loading && page?.messages.length === 0 && <p>No earlier messages in this program.</p>}
      {page?.has_older_messages && page.oldest_message_id != null && <button type="button" className="secondary-button" disabled={loading} onClick={() => { setLoading(true); setBefore(page.oldest_message_id ?? undefined); setAttempt(value => value + 1) }}>Load earlier messages ({page.older_message_count} remaining)</button>}
      <div className="earlier-mia-messages">{page?.messages.map(message => <article key={message.id ?? message.client_id}><strong>{message.author}</strong><p>{message.content}</p>{Boolean(message.attachments?.length) && <p className="earlier-mia-attachments">Earlier attachments: {message.attachments!.map(file => file.filename).join(', ')}</p>}</article>)}</div>
    </div>
  </section></div>
}
