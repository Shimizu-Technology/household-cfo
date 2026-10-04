import { useEffect, useRef, useState } from 'react'
import { fetchPrivateJson } from '../api'
import type { BaselineScope } from '../lib/financialBaseline'
export function ChallengeExport({ scope, cohortId }: { scope: BaselineScope; cohortId: number }) {
  return <Export key={`${scope.user_id}:${scope.household_id}:${cohortId}`} scope={scope} cohortId={cohortId} />
}
function Export({ scope, cohortId }: { scope: BaselineScope; cohortId: number }) {
  const [feelings, setFeelings] = useState(false),
    [accepted, setAccepted] = useState(false),
    [busy, setBusy] = useState(false),
    [error, setError] = useState<string | null>(null),
    [notice, setNotice] = useState<string | null>(null)
  const live = useRef(true),
    controller = useRef<AbortController | null>(null)
  useEffect(() => {
    live.current = true
    return () => {
      live.current = false
      controller.current?.abort()
    }
  }, [])
  async function download() {
    if (!accepted || busy) return
    const owned = new AbortController()
    controller.current = owned
    setBusy(true)
    setError(null)
    setNotice(null)
    try {
      const result = await fetchPrivateJson<{
        schema_version: number
        actor_scope: BaselineScope
        optional_reflections_included: boolean
        enrollment: { cohort_id: number }
      }>(`/api/v1/savings_challenge/export?include_reflections=${feelings}`, {
        signal: owned.signal,
        cache: 'no-store',
      })
      if (!live.current || owned.signal.aborted) return
      if (
        result.actor_scope.user_id !== scope.user_id ||
        result.actor_scope.household_id !== scope.household_id ||
        result.optional_reflections_included !== feelings ||
        result.enrollment?.cohort_id !== cohortId
      )
        throw new Error('Your private workspace changed. Reopen the export in the correct account.')
      const url = URL.createObjectURL(new Blob([JSON.stringify(result, null, 2)], { type: 'application/json' }))
      const anchor = document.createElement('a')
      anchor.href = url
      anchor.download = 'my-90-day-challenge.json'
      anchor.click()
      URL.revokeObjectURL(url)
      setAccepted(false)
      setNotice('Your private challenge record was downloaded. Keep the file somewhere you trust.')
    } catch (failure) {
      if (live.current && !owned.signal.aborted) {
        setError(failure instanceof Error ? failure.message : 'Private export unavailable. Try again.')
        setAccepted(false)
      }
    } finally {
      if (live.current && !owned.signal.aborted) setBusy(false)
    }
  }
  return (
    <details className="challenge-personal-export">
      <summary>Download your private challenge record</summary>
      <p>
        Download approved savings, plan revisions, daily reports and checkpoint history as a structured JSON file.
        Original statements, chat and pending proposals are excluded.
      </p>
      <fieldset disabled={busy}>
        <label>
          <input
            type="checkbox"
            checked={feelings}
            onChange={(event) => {
              setFeelings(event.target.checked)
              setAccepted(false)
            }}
          />
          Include my optional feeling history. Leave unchecked to exclude feelings.
        </label>
        <label>
          <input type="checkbox" checked={accepted} onChange={(event) => setAccepted(event.target.checked)} />
          Download this private file to my device. The app cannot recall downloaded copies.
        </label>
        <button type="button" disabled={!accepted} onClick={() => void download()}>
          {busy ? 'Preparing private export…' : 'Download reviewed records'}
        </button>
      </fieldset>
      {error && <p role="alert">{error}</p>}
      {notice && <p role="status">{notice}</p>}
    </details>
  )
}
