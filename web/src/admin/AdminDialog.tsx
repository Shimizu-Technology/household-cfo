import type { ReactNode } from 'react'
import { usePilotDialog } from '../lib/usePilotDialog'

// One dialog frame for the Admin side: a sheet on phones, a centred card on desktop.
// `locked` keeps the dialog open while something it started is still being saved, so its result is never lost.
export function AdminDialog({ title, onClose, children, labelId, locked = false }: { title: string; onClose: () => void; children: ReactNode; labelId: string; locked?: boolean }) {
  const close = locked ? () => {} : onClose
  const dialogRef = usePilotDialog(close)
  return <div className="pilot-dialog-overlay admin-dialog-overlay" role="presentation">
    <button type="button" className="pilot-dialog-backdrop" aria-label={`Close ${title.toLowerCase()}`} onClick={close} tabIndex={locked ? -1 : undefined} />
    <section ref={dialogRef} className="pilot-dialog admin-dialog" role="dialog" aria-modal="true" aria-labelledby={labelId} tabIndex={-1}>
      <header><h2 id={labelId}>{title}</h2><button type="button" className="secondary-button" onClick={close} disabled={locked}>Close</button></header>
      <div className="pilot-dialog-body admin-dialog-body">{children}</div>
    </section>
  </div>
}
