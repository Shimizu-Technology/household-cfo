import { useEffect, type RefObject } from 'react'

// Controls that accept typed text and can summon the phone keyboard.
// Shared by shell focus detection and its pointer hold; native pickers stay out.
export const TEXT_ENTRY_SELECTOR = 'input:not([type]), input:is([type="text"], [type="search"], [type="email"], [type="url"], [type="tel"], [type="password"], [type="number"]), textarea, [contenteditable="true"]'

// One keyboard/pointer policy for both navigation shells.
export function useShellTextEntryNavigation(shellRef: RefObject<HTMLElement | null>, rootSelector: string) {
  useEffect(() => {
    let heldRoot: HTMLElement | null = null
    let releaseTimer: number | undefined
    const root = shellRef.current?.closest<HTMLElement>(rootSelector)
    const updateFocus = (event?: FocusEvent) => {
      const active = event?.type === 'focusout' ? event.relatedTarget : document.activeElement
      root?.toggleAttribute('data-text-entry-focus', active instanceof Element && active.matches(TEXT_ENTRY_SELECTOR) && root.contains(active))
    }
    const releaseOnUp = () => {
      if (!heldRoot) return
      // A synthesized click follows pointerup; keep its target uncovered until
      // that dispatch finishes. The bounded fallback also covers legacy delayed
      // touch clicks and releases presses that produce no click.
      window.clearTimeout(releaseTimer)
      releaseTimer = window.setTimeout(release, 350)
    }
    const release = () => {
      window.clearTimeout(releaseTimer)
      releaseTimer = undefined
      const root = heldRoot
      heldRoot = null
      // Click has its target now. Release after its handlers commit, including
      // when animation frames are suspended by a background tab or test clock.
      queueMicrotask(() => root?.removeAttribute('data-field-pointer'))
    }
    const hold = () => {
      const active = document.activeElement
      const root = shellRef.current?.closest<HTMLElement>(rootSelector)
      if (window.innerWidth > 620 || !root || !active || !root.contains(active)
        || !active.matches(TEXT_ENTRY_SELECTOR)) return
      heldRoot = root
      root.setAttribute('data-field-pointer', '')
    }
    updateFocus()
    document.addEventListener('focusin', updateFocus)
    document.addEventListener('focusout', updateFocus)
    window.addEventListener('pointerup', releaseOnUp, true)
    document.addEventListener('pointerdown', hold, true)
    document.addEventListener('click', release, true)
    window.addEventListener('blur', release)
    document.addEventListener('pointercancel', release, true)
    return () => {
      window.clearTimeout(releaseTimer)
      root?.removeAttribute('data-text-entry-focus')
      document.removeEventListener('focusin', updateFocus)
      document.removeEventListener('focusout', updateFocus)
      window.removeEventListener('pointerup', releaseOnUp, true)
      heldRoot?.removeAttribute('data-field-pointer')
      document.removeEventListener('pointerdown', hold, true)
      document.removeEventListener('click', release, true)
      window.removeEventListener('blur', release)
      document.removeEventListener('pointercancel', release, true)
    }
  }, [shellRef, rootSelector])

}
