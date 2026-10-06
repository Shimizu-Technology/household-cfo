import { useState } from 'react'
import { createPortal } from 'react-dom'
import { usePilotDialog } from '../lib/usePilotDialog'
import './BankActivityResumeDialog.css'

export function BankActivityResumeDialog({ institutionName, busy, error, onClose, onConfirm }: {
  institutionName: string; busy: boolean; error?: string | null; onClose: () => void; onConfirm: () => void
}) {
  const [accepted, setAccepted] = useState(false)
  const ref = usePilotDialog(() => { if (!busy) onClose() })
  return createPortal(<div className="bank-resume-overlay">
    <button type="button" className="bank-resume-backdrop" aria-label="Close bank activity review" disabled={busy} onClick={onClose} tabIndex={-1} />
    <section ref={ref} className="bank-resume-dialog" role="dialog" aria-modal="true" aria-labelledby="bank-resume-title" tabIndex={-1}>
      <header><h2 id="bank-resume-title">Use new bank activity</h2><button type="button" className="secondary-button" disabled={busy} onClick={onClose}>Close</button></header>
      <div className="pilot-dialog-body">
        <p>Resume {institutionName} for your new financial picture using your existing bank connection.</p>
        <ul><li>Older transactions stay in History and cannot be approved into this picture.</li><li>A fresh sync updates linked accounts and makes newly received activity available for review.</li><li>Automatic merchant approvals stay off. Bank activity does not become savings or budget actuals without the required review.</li></ul>
        {error && <p role="alert" className="form-error">{error}</p>}
        <label><input type="checkbox" checked={accepted} disabled={busy} onChange={event => setAccepted(event.currentTarget.checked)} /><span>I want new activity from this bank included in my new financial picture.</span></label>
        <div className="bank-resume-actions"><button type="button" className="secondary-button" disabled={busy} onClick={onClose}>Keep paused</button><button type="button" className="primary-button" disabled={!accepted || busy} onClick={onConfirm}>{busy ? 'Enabling new activity' : 'Use new bank activity'}</button></div>
      </div>
    </section>
  </div>, document.body)
}
