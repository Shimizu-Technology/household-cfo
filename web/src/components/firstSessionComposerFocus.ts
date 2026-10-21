/** Let a requested chat prompt focus its composer unless another control takes over. */
export function scheduleFirstSessionComposerFocus(getComposer: () => HTMLTextAreaElement | null, isChatActive: () => boolean) {
  const origin = document.activeElement
  return window.setTimeout(() => {
    const composer = getComposer()
    if (!composer?.isConnected || !isChatActive()) return
    const active = document.activeElement
    if (active && active !== document.body && active !== origin && active !== composer) return
    composer.focus({ preventScroll: true })
  }, 80)
}
