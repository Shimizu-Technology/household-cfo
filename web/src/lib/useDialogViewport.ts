import { useEffect } from 'react'
import { revealDialogControl } from './dialogFocus'

// Mobile keyboards can shrink the visual viewport without changing dvh.
// Keep dialogs inside the visible area, including a keyboard-induced pan.
export function useDialogViewport() {
  useEffect(() => {
    const viewport = window.visualViewport
    if (!viewport) return
    const style = document.documentElement.style
    const names = ['--dialog-viewport-height', '--dialog-viewport-top'] as const
    const previous = names.map((name) => style.getPropertyValue(name))
    let frame = 0
    let revealFrame = 0
    function update() {
      // Leave pinch zoom to the browser; resizing the dialog while zooming
      // would reflow the content the reader is trying to inspect.
      if (Math.abs(viewport!.scale - 1) > 0.01) return
      style.setProperty(names[0], `${viewport!.height}px`)
      style.setProperty(names[1], `${viewport!.offsetTop}px`)
      // Let browser layout settle after the panel changes size.
      // Revealing in this same frame can be undone by that layout adjustment.
      scheduleReveal()
    }
    function revealActiveField() {
      if (Math.abs(viewport!.scale - 1) > 0.01) return
      const active = document.activeElement
      if (!(active instanceof HTMLElement) || !active.matches('button, a[href], summary, input, textarea, select, [contenteditable="true"]')) return
      const dialog = active.closest('[role="dialog"], dialog')
      if (!dialog) return
      revealDialogControl(active, dialog)
    }
    function scheduleReveal() {
      window.cancelAnimationFrame(revealFrame)
      revealFrame = window.requestAnimationFrame(revealActiveField)
    }
    function schedule() {
      window.cancelAnimationFrame(frame)
      window.cancelAnimationFrame(revealFrame)
      frame = window.requestAnimationFrame(update)
    }
    // Observe content too: individual font faces and async rows can reflow
    // before the entire FontFaceSet finishes loading.
    const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(scheduleReveal)
    function watchFocusedDialog() {
      observer?.disconnect()
      const active = document.activeElement
      const dialog = active instanceof HTMLElement ? active.closest('[role="dialog"], dialog') : null
      if (!dialog) return
      observer?.observe(dialog)
      Array.from(dialog.children).forEach(child => observer?.observe(child))
      // Constrained scrolling bodies keep the same box when their form or
      // other content reflows. Watch that content as well as the fixed body.
      dialog.querySelectorAll('.pilot-dialog-body, .mia-assist-body').forEach(body => {
        Array.from(body.children).forEach(child => observer?.observe(child))
      })
    }
    document.addEventListener('focusin', watchFocusedDialog)
    watchFocusedDialog()
    update()
    viewport.addEventListener('resize', schedule)
    viewport.addEventListener('scroll', schedule)
    // Late font loads can move a focused field after the keyboard settles.
    document.fonts?.addEventListener('loadingdone', scheduleReveal)
    document.fonts?.addEventListener('loadingerror', scheduleReveal)
    return () => {
      window.cancelAnimationFrame(frame)
      window.cancelAnimationFrame(revealFrame)
      observer?.disconnect()
      document.removeEventListener('focusin', watchFocusedDialog)
      viewport.removeEventListener('resize', schedule)
      viewport.removeEventListener('scroll', schedule)
      document.fonts?.removeEventListener('loadingdone', scheduleReveal)
      document.fonts?.removeEventListener('loadingerror', scheduleReveal)
      names.forEach((name, index) => {
        if (previous[index]) style.setProperty(name, previous[index])
        else style.removeProperty(name)
      })
    }
  }, [])
}
