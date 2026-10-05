import { useEffect, useRef } from 'react'
import { revealDialogControl } from './dialogFocus'

export function usePilotDialog(onClose: () => void) {
  const dialogRef = useRef<HTMLElement | null>(null)
  const onCloseRef = useRef(onClose)

  useEffect(() => {
    onCloseRef.current = onClose
  }, [onClose])

  useEffect(() => {
    const previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null
    const previousBodyOverflow = document.body.style.overflow
    const dialog = dialogRef.current
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
      dialog.scrollTop = 0
      const first = focusableElements()[0]
      const panel = dialog.getBoundingClientRect()
      const control = first?.getBoundingClientRect()
      const destination = first && control && control.top >= panel.top && control.bottom <= panel.bottom ? first : dialog
      destination.focus({ preventScroll: true })
    })

    function handleKeyDown(event: globalThis.KeyboardEvent) {
      if (event.key === 'Escape') {
        event.preventDefault()
        event.stopPropagation()
        onCloseRef.current()
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
      window.cancelAnimationFrame(focusFrame)
      document.removeEventListener('keydown', handleKeyDown)
      document.removeEventListener('focusin', handleFocusIn)
      document.body.style.overflow = previousBodyOverflow
      previousFocus?.focus({ preventScroll: true })
    }
  }, [])

  return dialogRef
}
