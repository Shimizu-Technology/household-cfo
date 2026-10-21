import { useEffect, type Dispatch, type RefObject, type SetStateAction } from 'react'

/** Anchor a new reply until the participant starts interacting with history. */
export function useMiaEntryAnchor({ active, messageKey, loading, chatRef, awayRef, anchor, setShowScrollButton }: {
  active: boolean
  messageKey: string
  loading: boolean
  chatRef: RefObject<HTMLElement | null>
  awayRef: RefObject<boolean>
  anchor: (behavior: ScrollBehavior) => void
  setShowScrollButton: Dispatch<SetStateAction<boolean>>
}) {
  useEffect(() => {
    const chat = chatRef.current
    if (!active || !chat) return

    let settled = false
    const away = () => { awayRef.current = true }
    const reanchor = () => { if (!settled && !awayRef.current) anchor('auto') }
    // A press on Load earlier is intent too: its target must not move before release.
    chat.addEventListener('pointerdown', away, { passive: true })
    chat.addEventListener('wheel', away, { passive: true })
    chat.addEventListener('touchmove', away, { passive: true })
    chat.addEventListener('keydown', away)
    const frame = requestAnimationFrame(() => {
      if (settled || awayRef.current) return
      anchor('auto')
      setShowScrollButton(false)
    })
    const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(reanchor)
    observer?.observe(chat)
    Array.from(chat.children).forEach(child => observer?.observe(child))
    chat.addEventListener('load', reanchor, true)
    const settle = window.setTimeout(() => { settled = true }, 2500)
    return () => {
      settled = true
      cancelAnimationFrame(frame)
      window.clearTimeout(settle)
      observer?.disconnect()
      chat.removeEventListener('pointerdown', away)
      chat.removeEventListener('wheel', away)
      chat.removeEventListener('touchmove', away)
      chat.removeEventListener('keydown', away)
      chat.removeEventListener('load', reanchor, true)
    }
  }, [active, messageKey, loading, chatRef, awayRef, anchor, setShowScrollButton])
}
