import { useEffect, useRef } from 'react'
import { dialogExit } from './dialogExit'
import { revealDialogControl } from './dialogFocus'

// A confirmation can open over another dialog; only the topmost one traps focus
// and answers Escape, so the one underneath waits until it closes.
const openDialogs: symbol[] = []
// The page scrolls again only when the last dialog closes. Each dialog restoring
// its own saved value would unlock the page while a confirmation is still open.
let overflowBeforeFirstDialog = ''

export function usePilotDialog(onClose: () => void, onDismiss?: () => void) {
  const dialogRef = useRef<HTMLElement | null>(null)
  const onCloseRef = useRef(onClose)
  const onDismissRef = useRef(onDismiss)
  const cancelExit = useRef<(() => void) | null>(null)
  const requestClose = () => {
    if (dialogRef.current?.dataset.dialogClosing) return
    onDismissRef.current?.()
    cancelExit.current = dialogExit(dialogRef.current, () => onCloseRef.current())
  }

  useEffect(() => {
    onCloseRef.current = onClose
    onDismissRef.current = onDismiss
  }, [onClose, onDismiss])

  useEffect(() => {
    const token = Symbol('pilot-dialog')
    if (openDialogs.length === 0) overflowBeforeFirstDialog = document.body.style.overflow
    openDialogs.push(token)
    const isTopmost = () => openDialogs[openDialogs.length - 1] === token
    const previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null
    const dialog = dialogRef.current
    dialog?.setAttribute('data-dialog-panel', 'true')
    dialog?.parentElement?.setAttribute('data-dialog-surface', 'true')
    const focusableSelector = 'button:not([disabled]), select:not([disabled]), textarea:not([disabled]), input:not([disabled]):not([type="hidden"]), [href], [tabindex]:not([tabindex="-1"])'
    const focusableElements = () => Array.from(dialog?.querySelectorAll<HTMLElement>(focusableSelector) ?? [])
      .filter((element) => {
        if (typeof element.checkVisibility === 'function') return element.checkVisibility({ checkVisibilityCSS: true })
        for (let node: HTMLElement | null = element; node && node !== dialog; node = node.parentElement) {
          const style = getComputedStyle(node)
          if (node.hidden || style.display === 'none' || style.visibility === 'hidden') return false
        }
        return true
      })
    function revealFocus(element: HTMLElement) {
      element.focus({ preventScroll: true })
      if (dialog) revealDialogControl(element, dialog)
    }
    const focusFrame = window.requestAnimationFrame(() => {
      if (!dialog) return
      const active = document.activeElement
      if (active instanceof HTMLElement && dialog.contains(active)) {
        revealDialogControl(active, dialog)
        return
      }
      dialog.scrollTop = 0
      const first = focusableElements()[0]
      const panel = dialog.getBoundingClientRect()
      const control = first?.getBoundingClientRect()
      const destination = first && control && control.top >= panel.top && control.bottom <= panel.bottom ? first : dialog
      destination.focus({ preventScroll: true })
    })

    function handleKeyDown(event: globalThis.KeyboardEvent) {
      if (!isTopmost()) return
      if (dialog?.dataset.dialogClosing) { event.preventDefault(); event.stopPropagation(); return }
      if (event.key === 'Escape') {
        event.preventDefault()
        event.stopPropagation()
        onDismissRef.current?.()
        cancelExit.current = dialogExit(dialogRef.current, () => onCloseRef.current())
        return
      }
      if (event.key !== 'Tab') return

      const elements = focusableElements()
      if (elements.length === 0) {
        event.preventDefault()
        dialog?.focus()
        return
      }

      const first = elements[0]
      const last = elements[elements.length - 1]
      if (document.activeElement === dialog) {
        event.preventDefault()
        revealFocus(event.shiftKey ? last : first)
      } else if (event.shiftKey && document.activeElement === first) {
        event.preventDefault()
        revealFocus(last)
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault()
        revealFocus(first)
      }
    }

    function handleFocusIn(event: FocusEvent) {
      if (!isTopmost()) return
      if (dialog?.contains(event.target as Node)) {
        if (event.target instanceof HTMLElement) revealDialogControl(event.target, dialog)
        return
      }
      const destination = focusableElements()[0] ?? dialog
      destination?.focus()
    }

    document.addEventListener('keydown', handleKeyDown)
    document.addEventListener('focusin', handleFocusIn)
    document.body.style.overflow = 'hidden'
    return () => {
      cancelExit.current?.()
      window.cancelAnimationFrame(focusFrame)
      const position = openDialogs.indexOf(token)
      if (position >= 0) openDialogs.splice(position, 1)
      document.removeEventListener('keydown', handleKeyDown)
      document.removeEventListener('focusin', handleFocusIn)
      if (openDialogs.length === 0) document.body.style.overflow = overflowBeforeFirstDialog
      // An account action may have closed its disclosure while opening us.
      // Its button is then hidden; return to the nearest visible summary,
      // after unmount, rather than racing a parent's animation-frame fallback.
      let destination = previousFocus
      for (let node = previousFocus?.parentElement; node; node = node.parentElement) {
        if (node instanceof HTMLDetailsElement && !node.open) {
          const summary = node.querySelector<HTMLElement>(':scope > summary')
          if (summary && !summary.contains(destination)) destination = summary
        }
      }
      destination?.focus({ preventScroll: true })
    }
  }, [])

  return { dialogRef, requestClose }
}
