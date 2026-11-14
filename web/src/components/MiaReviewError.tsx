import { useLayoutEffect, useRef } from 'react'

/** Keep a failed decision beside its controls and wholly inside the reading area. */
export function MiaReviewError({ message }: { message?: string | null }) {
  const notice = useRef<HTMLParagraphElement>(null)
  useLayoutEffect(() => {
    const element = notice.current
    if (!message || !element) return
    const history = element.closest<HTMLElement>('.chat-card')
    const reveal = () => {
      if (!history) { element.scrollIntoView?.({ block: 'nearest', behavior: 'auto' }); return }
      const box = element.getBoundingClientRect(), area = history.getBoundingClientRect()
      if (box.bottom > area.bottom) history.scrollTop += box.bottom - area.bottom
      else if (box.top < area.top) history.scrollTop -= area.top - box.top
    }
    reveal()
    const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(reveal)
    observer?.observe(element)
    if (history) observer?.observe(history)
    const frame = window.requestAnimationFrame?.(reveal)
    return () => { if (frame !== undefined) window.cancelAnimationFrame?.(frame); observer?.disconnect() }
  }, [message])
  return message ? <p ref={notice} className="chat-error" role="alert">{message}</p> : null
}
