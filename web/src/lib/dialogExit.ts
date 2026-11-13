const exits = new WeakMap<HTMLElement, () => void>()

/** Keep a mounted panel and its scrim until their CSS exit finishes. Financial
 * actions are never delayed here: callers use this only for dismissal. */
export function dialogExit(panel: HTMLElement | null, done: () => void) {
  if (!panel || typeof CSS === 'undefined' || !CSS.supports('transition-behavior', 'allow-discrete')) { done(); return () => {} }
  const surface = panel instanceof HTMLDialogElement ? null : panel.closest<HTMLElement>('[data-dialog-surface]') ?? panel.parentElement
  const existing = exits.get(panel)
  if (existing) return existing
  panel.dataset.dialogClosing = 'true'
  surface?.setAttribute('data-dialog-closing', 'true')
  // Force the new styles to be resolved before asking for the transitions.
  void getComputedStyle(panel).opacity
  let cancelled = false
  const finish = () => {
    if (cancelled) return
    cancelled = true
    exits.delete(panel)
    window.clearTimeout(deadline)
    done()
    // A guarded close (e.g. a pending save) may retain the same panel.
    delete panel.dataset.dialogClosing
    surface?.removeAttribute('data-dialog-closing')
  }
  const animations = [...panel.getAnimations(), ...(surface?.getAnimations() ?? [])]
  const deadline = window.setTimeout(finish, 200)
  void Promise.allSettled(animations.map(animation => animation.finished)).then(finish)
  const cancel = () => {
    cancelled = true
    exits.delete(panel)
    window.clearTimeout(deadline)
    delete panel.dataset.dialogClosing
    surface?.removeAttribute('data-dialog-closing')
  }
  exits.set(panel, cancel)
  return cancel
}
