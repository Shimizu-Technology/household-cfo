import { useEffect, useId, useRef, useState, type ReactNode, type RefObject } from 'react'

export type ChatMoreItem = {
  key: string
  label: string
  onSelect: (trigger: HTMLButtonElement) => void
  disabled?: boolean
}

/**
 * Phone chat header: one "More" button holds the secondary chat controls so
 * the conversation keeps the screen. Items are plain buttons (a disclosure,
 * not an ARIA menu) so they read and test like the desktop controls.
 */
export function ChatMoreMenu({ items, note, triggerRef }: { items: ChatMoreItem[]; note?: ReactNode; triggerRef?: RefObject<HTMLButtonElement | null> }) {
  const [open, setOpen] = useState(false)
  const ownTrigger = useRef<HTMLButtonElement | null>(null)
  const trigger = triggerRef ?? ownTrigger
  const container = useRef<HTMLDivElement | null>(null)
  const menuId = useId()

  useEffect(() => {
    if (!open) return
    const dismiss = (event: PointerEvent) => {
      if (!container.current?.contains(event.target as Node)) setOpen(false)
    }
    document.addEventListener('pointerdown', dismiss)
    container.current?.querySelector<HTMLButtonElement>('.chat-more-menu button:not(:disabled)')?.focus({ preventScroll: true })
    return () => document.removeEventListener('pointerdown', dismiss)
  }, [open])

  return (
    <div
      ref={container}
      className="chat-more"
      onKeyDown={(event) => {
        if (event.key !== 'Escape' || !open) return
        event.preventDefault()
        event.stopPropagation()
        setOpen(false)
        trigger.current?.focus({ preventScroll: true })
      }}
      onBlur={(event) => {
        if (event.relatedTarget && !event.currentTarget.contains(event.relatedTarget as Node)) setOpen(false)
      }}
    >
      <button
        ref={trigger}
        type="button"
        className="chat-more-button"
        aria-label="More chat options"
        aria-expanded={open}
        aria-controls={menuId}
        onClick={() => setOpen((current) => !current)}
      >
        <MoreIcon />
      </button>
      {open && (
        <div id={menuId} className="chat-more-menu" role="group" aria-label="Chat options">
          {note && <p className="chat-more-note">{note}</p>}
          {items.map((item) => (
            <button
              key={item.key}
              type="button"
              disabled={item.disabled}
              onClick={() => {
                const button = trigger.current
                setOpen(false)
                if (!button) return
                button.focus({ preventScroll: true })
                item.onSelect(button)
              }}
            >
              {item.label}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

function MoreIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" width="20" height="20">
      <circle cx="5.5" cy="12" r="1.75" fill="currentColor" />
      <circle cx="12" cy="12" r="1.75" fill="currentColor" />
      <circle cx="18.5" cy="12" r="1.75" fill="currentColor" />
    </svg>
  )
}
