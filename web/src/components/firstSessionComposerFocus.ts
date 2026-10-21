/** Let a requested chat prompt focus its composer unless another control takes over. */
export function scheduleFirstSessionComposerFocus(getComposer: () => HTMLTextAreaElement | null, isChatActive: () => boolean) {
  const origin = document.activeElement
  const cancel = () => {
    window.clearTimeout(timer)
    document.removeEventListener('pointerdown', yieldToIntent, true)
    document.removeEventListener('keydown', yieldToIntent, true)
  }
  const yieldToIntent = (event: Event) => {
    // Touching a button need not move DOM focus in Safari. The press itself
    // takes precedence over this older request, even if origin still has focus.
    if (event.target !== getComposer()) cancel()
  }
  const timer = window.setTimeout(() => {
    cancel()
    const composer = getComposer()
    if (!composer?.isConnected || !isChatActive()) return
    const active = document.activeElement
    if (active && active !== document.body && active !== origin && active !== composer) return
    composer.focus({ preventScroll: true })
  }, 80)
  document.addEventListener('pointerdown', yieldToIntent, true)
  document.addEventListener('keydown', yieldToIntent, true)
  return cancel
}
