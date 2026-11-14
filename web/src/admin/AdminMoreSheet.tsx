import { useRef, type ReactNode, type PointerEvent } from 'react'
import { createPortal } from 'react-dom'
import { usePilotDialog } from '../lib/usePilotDialog'

// Uses the participant sheet's surface and motion, and the shared dialog's
// synchronous dismissal, focus ownership and reference-counted body lock.
export function AdminMoreSheet({ children, onClose, title = 'More' }: { children: ReactNode; onClose: () => void; title?: string }) {
  const { dialogRef, requestClose } = usePilotDialog(onClose)
  const drag = useRef<{ id: number; y: number; time: number; distance: number } | null>(null)
  const start = (event: PointerEvent<HTMLDivElement>) => {
    if (drag.current || !event.isPrimary || event.button !== 0) return
    drag.current = { id: event.pointerId, y: event.clientY, time: event.timeStamp, distance: 0 }
    event.currentTarget.setPointerCapture(event.pointerId)
    dialogRef.current?.style.setProperty('transition', 'none')
  }
  const move = (event: PointerEvent<HTMLDivElement>) => {
    const current = drag.current
    if (!current || current.id !== event.pointerId) return
    current.distance = event.clientY - current.y
    const offset = current.distance < 0 ? -Math.sqrt(-current.distance) : current.distance
    if (dialogRef.current) dialogRef.current.style.transform = `translateY(${offset}px)`
  }
  const finish = (event: PointerEvent<HTMLDivElement>, cancelled = false) => {
    const current = drag.current
    if (!current || current.id !== event.pointerId) return
    drag.current = null
    event.currentTarget.releasePointerCapture(event.pointerId)
    dialogRef.current?.style.removeProperty('transition')
    if (!cancelled && (current.distance > 80 || (current.distance > 8 && current.distance / Math.max(1, event.timeStamp - current.time) > 0.11))) requestClose()
    else dialogRef.current?.style.removeProperty('transform')
  }
  return createPortal(<div className="tabs-tools-surface admin-more-surface" data-dialog-surface>
    {/* Consume the backdrop's own click before unmounting: a touch must not hit the page underneath. */}
    <button type="button" className="tabs-tools-backdrop" aria-label="Close menu" tabIndex={-1} onClick={requestClose} />
    <section ref={dialogRef} className="tabs-secondary admin-more-sheet" role="dialog" aria-modal="true" aria-labelledby="admin-more-title" tabIndex={-1} id="admin-more-sections"
      // The nested account disclosure must not collapse on document pointerdown:
      // moving the sheet between down/up would steal its Close or drag gesture.
      onPointerDown={event => event.stopPropagation()}>
      <div className="tabs-sheet-grab" aria-hidden="true" onPointerDown={start} onPointerMove={move} onPointerUp={event => finish(event)} onPointerCancel={event => finish(event, true)}><span /></div>
      <header><strong id="admin-more-title">{title}</strong><button type="button" className="tabs-tools-close" aria-label="Close menu" onClick={requestClose}>×</button></header>
      <div className="tabs-tools-list">{children}</div>
    </section>
  </div>, document.body)
}
