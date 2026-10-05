import { useEffect, useState, type ReactNode } from 'react'
import { ApiRequestError, fetchDailyPage } from '../api'
import { dailyResponseMatches } from '../lib/dailyChallenge'
import type { DailyCollection, DailyPage, DailyScope } from '../lib/dailyChallenge'
export function DailyRecordPage<T>({ collection, parentId, scope, refresh, title, render, onDenied }: { collection: DailyCollection; parentId?: number; scope: DailyScope; refresh: number; title: string; render: (record: T) => ReactNode; onDenied: () => void }) {
  const [cursor, setCursor] = useState<number | null>(null)
  const [history, setHistory] = useState<Array<number | null>>([])
  const [page, setPage] = useState<DailyPage<T> | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [attempt, setAttempt] = useState(0)
  useEffect(() => {
    const controller = new AbortController(); let live = true
    fetchDailyPage<T>(collection,cursor,parentId,controller.signal).then(result => {
      if (!dailyResponseMatches(result,scope)) throw new ApiRequestError('Private workspace changed.',{status:403})
      if (live) { setPage(result); setLoading(false); setError(null) }
    }).catch(failure => { if (live) { setLoading(false); setError(failure instanceof Error ? failure.message : 'These records are unavailable.'); if (failure instanceof ApiRequestError && [401,403,404].includes(failure.status)) onDenied() } })
    return () => { live = false; controller.abort() }
  },[collection,cursor,parentId,scope,refresh,attempt,onDenied])
  return <section aria-label={title}><h3>{title}</h3>{loading && <p role="status">Loading up to 50 records…</p>}{error && <div role="alert"><p>{error}</p><button type="button" onClick={() => { setLoading(true); setAttempt(value=>value+1) }}>Retry {title.toLowerCase()}</button></div>}{!loading && !error && <>{page?.records.map(render)}{!page?.records.length && <p>No records on this page.</p>}</>}<div className="daily-actions"><button type="button" disabled={loading || !history.length} onClick={()=>{setLoading(true);setCursor(history.at(-1)!);setHistory(history.slice(0,-1))}}>Previous {title.toLowerCase()}</button><button type="button" disabled={loading || page?.next_cursor == null} onClick={()=>{setLoading(true);setHistory([...history,cursor]);setCursor(page!.next_cursor)}}>Next {title.toLowerCase()}</button></div></section>
}

export function DailyHistory({ title, children }: { title: string; children: () => ReactNode }) {
  const [open, setOpen] = useState(false)
  return <details onToggle={event=>setOpen(event.currentTarget.open)}><summary>{title}</summary>{open && children()}</details>
}
