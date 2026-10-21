import { useEffect, useRef, useState } from 'react'
import { fetchPrivateJson } from '../api'
import { printableChallengeRecord, type PrivateChallengeRecord } from '../lib/privateChallengeRecord'
import type { BaselineScope } from '../lib/financialBaseline'
import { participantErrorMessage } from '../lib/participantErrorMessage'
import { SavingsRowContent } from './SavingsRow'
type ExportProps = { scope: BaselineScope; cohortId: number; variant?: 'panel' | 'row' }
export function ChallengeExport({ scope, cohortId, variant }: ExportProps) {
  return <Export key={`${scope.user_id}:${scope.household_id}:${cohortId}`} scope={scope} cohortId={cohortId} variant={variant} />
}
function Export({ scope, cohortId, variant = 'panel' }: ExportProps) {
  const [format, setFormat] = useState<'printable' | 'json'>('printable')
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
      const result = await fetchPrivateJson<PrivateChallengeRecord>(`/api/v1/savings_challenge/export?include_reflections=${feelings}`, {
        signal: owned.signal,
        cache: 'no-store',
      })
      if (!live.current || owned.signal.aborted) return
      if (
        result.schema_version !== 1 ||
        result.actor_scope.user_id !== scope.user_id ||
        result.actor_scope.household_id !== scope.household_id ||
        result.optional_reflections_included !== feelings ||
        result.enrollment?.cohort_id !== cohortId
      )
        throw new Error('Your private workspace changed. Reopen the export in the correct account.')
      const content = format === 'printable' ? printableChallengeRecord(result) : JSON.stringify(result, null, 2)
      const url = URL.createObjectURL(new Blob([content], { type: format === 'printable' ? 'text/html;charset=utf-8' : 'application/json' }))
      const anchor = document.createElement('a')
      anchor.href = url
      anchor.download = format === 'printable' ? 'my-90-day-challenge.html' : 'my-90-day-challenge.json'
      anchor.click()
      URL.revokeObjectURL(url)
      setAccepted(false)
      setNotice('Downloaded. Keep the file somewhere you trust.')
    } catch (failure) {
      if (live.current && !owned.signal.aborted) {
        setError(participantErrorMessage(failure, 'Private export unavailable. Try again.'))
        setAccepted(false)
      }
    } finally {
      if (live.current && !owned.signal.aborted) setBusy(false)
    }
  }
  return (
    <details className={variant === 'row' ? 'savings-row-group savings-export' : 'challenge-personal-export'}>
      {variant === 'row'
        ? <summary className="savings-row"><SavingsRowContent label="Download your record" description="Keep or print a private copy" /></summary>
        : <summary>Download your record</summary>}
      <div className={variant === 'row' ? 'savings-row-body' : undefined}>
      <p>
        A private copy of what you’ve confirmed: money set aside, target changes and check-ins. Open it in your browser to print or save it as a PDF.
        Statements, chat and anything you haven’t confirmed are left out.
      </p>
      <fieldset disabled={busy}>
        <label>Record format<select value={format} onChange={event => { setFormat(event.target.value as 'printable' | 'json'); setAccepted(false) }}><option value="printable">Readable copy · print or save as PDF</option><option value="json">Data file (JSON) · everything, for other apps</option></select></label>
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
          {busy ? 'Preparing your copy…' : 'Download my record'}
        </button>
      </fieldset>
      {error && <p role="alert">{error}</p>}
      {notice && <p role="status">{notice}</p>}
      </div>
    </details>
  )
}
