import { useEffect, useId, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { registerConfirmHost, type ConfirmRequest } from '../lib/confirmAction'
import { usePilotDialog } from '../lib/usePilotDialog'

function ConfirmDialog({ request, onAnswer }: { request: ConfirmRequest; onAnswer: (confirmed: boolean) => void }) {
  const id = useId()
  const dialogRef = usePilotDialog(() => onAnswer(false))
  return (
    <div className="clear-chat-overlay confirm-overlay" role="presentation">
      <button type="button" className="clear-chat-backdrop" tabIndex={-1} aria-hidden="true" onClick={() => onAnswer(false)} />
      <section ref={dialogRef} className="clear-chat-dialog confirm-dialog" role="alertdialog" aria-modal="true" aria-labelledby={`${id}-title`} aria-describedby={`${id}-copy`} tabIndex={-1}>
        <h3 id={`${id}-title`}>{request.title ?? 'Are you sure?'}</h3>
        <p id={`${id}-copy`}>{request.message}</p>
        <div className="clear-chat-dialog-actions">
          <button type="button" className="secondary" onClick={() => onAnswer(false)}>{request.cancelLabel ?? 'Cancel'}</button>
          <button type="button" className={request.caution ? 'danger' : 'primary'} onClick={() => onAnswer(true)}>{request.confirmLabel ?? 'Continue'}</button>
        </div>
      </section>
    </div>
  )
}

export function ConfirmHost() {
  const [queue, setQueue] = useState<ConfirmRequest[]>([])
  const pending = useRef<ConfirmRequest[]>([])

  useEffect(() => {
    const unregister = registerConfirmHost((request) => {
      pending.current = [...pending.current, request]
      setQueue(pending.current)
    })
    return () => {
      unregister()
      pending.current.forEach((request) => request.resolve(false))
      pending.current = []
    }
  }, [])

  const current = queue[0]
  if (!current) return null
  return createPortal(
    <ConfirmDialog
      key={queue.length + current.message}
      request={current}
      onAnswer={(confirmed) => {
        pending.current = pending.current.slice(1)
        setQueue(pending.current)
        current.resolve(confirmed)
      }}
    />,
    document.body,
  )
}
