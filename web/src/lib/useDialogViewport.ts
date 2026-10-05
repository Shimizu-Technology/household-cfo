import { useEffect } from 'react'

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
    function update() {
      // Leave pinch zoom to the browser; resizing the dialog while zooming
      // would reflow the content the reader is trying to inspect.
      if (Math.abs(viewport!.scale - 1) > 0.01) return
      style.setProperty(names[0], `${viewport!.height}px`)
      style.setProperty(names[1], `${viewport!.offsetTop}px`)
      const active = document.activeElement
      if (!(active instanceof HTMLElement) || !active.matches('input, textarea, select, [contenteditable="true"]')) return
      const dialog = active.closest('[role="dialog"], dialog')
      if (!dialog) return
      const control = active.getBoundingClientRect()
      const panel = dialog.getBoundingClientRect()
      if (control.top < panel.top || control.bottom > panel.bottom) {
        active.scrollIntoView?.({ block: 'nearest', inline: 'nearest' })
      }
    }
    function schedule() {
      window.cancelAnimationFrame(frame)
      frame = window.requestAnimationFrame(update)
    }
    update()
    viewport.addEventListener('resize', schedule)
    viewport.addEventListener('scroll', schedule)
    return () => {
      window.cancelAnimationFrame(frame)
      viewport.removeEventListener('resize', schedule)
      viewport.removeEventListener('scroll', schedule)
      names.forEach((name, index) => {
        if (previous[index]) style.setProperty(name, previous[index])
        else style.removeProperty(name)
      })
    }
  }, [])
}
