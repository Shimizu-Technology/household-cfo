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
    const interactionTarget = chat.parentElement ?? chat

    let settled = false
    const away = () => { awayRef.current = true }
    let resizeFrame = 0
    const reanchor = () => {
      cancelAnimationFrame(resizeFrame)
      resizeFrame = requestAnimationFrame(() => { if (!settled && !awayRef.current) anchor('auto') })
    }
    // A press on Load earlier is intent too: its target must not move before release.
    interactionTarget.addEventListener('pointerdown', away, { passive: true })
    interactionTarget.addEventListener('wheel', away, { passive: true })
    interactionTarget.addEventListener('touchmove', away, { passive: true })
    interactionTarget.addEventListener('keydown', away)
    interactionTarget.addEventListener('focusin', away)
    const frame = requestAnimationFrame(() => {
      if (settled || awayRef.current) return
      anchor('auto')
      setShowScrollButton(false)
    })
    const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(reanchor)
    observer?.observe(chat)
    Array.from(chat.children).forEach(child => observer?.observe(child))
    chat.addEventListener('load', reanchor, true)
    return () => {
      settled = true
      cancelAnimationFrame(frame)
      cancelAnimationFrame(resizeFrame)
      observer?.disconnect()
      interactionTarget.removeEventListener('pointerdown', away)
      interactionTarget.removeEventListener('wheel', away)
      interactionTarget.removeEventListener('touchmove', away)
      interactionTarget.removeEventListener('keydown', away)
      interactionTarget.removeEventListener('focusin', away)
      chat.removeEventListener('load', reanchor, true)
    }
  }, [active, messageKey, loading, chatRef, awayRef, anchor, setShowScrollButton])
}
