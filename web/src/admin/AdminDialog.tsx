import type { ReactNode } from 'react'
import { usePilotDialog } from '../lib/usePilotDialog'

// One dialog frame for the Admin side: a sheet on phones, a centred card on desktop.
export function AdminDialog({ title, onClose, children, labelId }: { title: string; onClose: () => void; children: ReactNode; labelId: string }) {
  const dialogRef = usePilotDialog(onClose)
  return <div className="pilot-dialog-overlay admin-dialog-overlay" role="presentation">
    <button type="button" className="pilot-dialog-backdrop" aria-label={`Close ${title.toLowerCase()}`} onClick={onClose} />
    <section ref={dialogRef} className="pilot-dialog admin-dialog" role="dialog" aria-modal="true" aria-labelledby={labelId} tabIndex={-1}>
      <header><h2 id={labelId}>{title}</h2><button type="button" className="secondary-button" onClick={onClose}>Close</button></header>
      <div className="pilot-dialog-body admin-dialog-body">{children}</div>
    </section>
  </div>
}
