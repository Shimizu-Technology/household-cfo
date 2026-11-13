const exits = new WeakMap<HTMLElement, () => void>()
const noExit = () => {}

/** Dismiss the owner now. Only a detached, inert visual copy may outlive it.
 * Native dialogs and private/media panels close without a copy. Unsupported
 * browsers and CSS-free tests also keep synchronous dismissal. */
export function dialogExit(panel: HTMLElement | null, done: () => void) {
  const existing = panel && exits.get(panel)
  if (existing) return existing
  const surface = panel?.closest<HTMLElement>('[data-dialog-surface]')
  const parent = surface?.parentElement
  const privateContent = '[data-dialog-private], img, picture, iframe, object, embed, canvas, video, audio, image, use[href], script, style, link, input[type="password"], input[type="file"], input[type="image"]'
  const canCopy = panel && surface && parent && panel.tagName !== 'DIALOG'
    && 'inert' in HTMLElement.prototype && typeof panel.animate === 'function'
    && !surface.matches(privateContent) && !surface.querySelector(privateContent)
    && ![surface, ...surface.querySelectorAll('[style]')].some(node => /url\s*\(/i.test(node.getAttribute('style') ?? ''))
    && parseFloat(getComputedStyle(panel).transitionDuration) > 0
  // Capture while layout and inherited brand styles still belong to the owner.
  const position = canCopy ? Array.from(parent.childNodes).indexOf(surface) : -1
  const copy = canCopy ? surface.cloneNode(true) as HTMLElement : null
  const originalNodes = copy ? [surface!, ...surface!.querySelectorAll<HTMLElement>('*')] : []
  const copyNodes = copy ? [copy, ...copy.querySelectorAll<HTMLElement>('*')] : []
  const panelIndex = originalNodes.indexOf(panel!)
  const panelStyle = copy ? getComputedStyle(panel!) : null
  const from = panelStyle ? { opacity: panelStyle.opacity, transform: panelStyle.transform } : null
  const reduced = copy && window.matchMedia('(prefers-reduced-motion: reduce)').matches
  const scroll = originalNodes.map(node => [node.scrollLeft, node.scrollTop])
  copyNodes.forEach((node, index) => {
    const original = originalNodes[index]
    // No duplicate IDs, form associations, autofocus, inline handlers or tab stops.
    for (const attr of [...node.attributes]) {
      if (/^(id|name|form|autofocus|aria-.+|on.+)$/i.test(attr.name)) node.removeAttribute(attr.name)
    }
    // Advance every copied CSS animation to its finished state, including
    // descendant scrims. Removing animations would lose forwards/both fills.
    node.style.setProperty('animation-duration', '0s', 'important')
    node.style.setProperty('animation-delay', '0s', 'important')
    node.style.setProperty('transition', 'none', 'important')
    node.tabIndex = -1
    node.style.setProperty('pointer-events', 'none', 'important')
    if (node instanceof HTMLInputElement && original instanceof HTMLInputElement) {
      node.value = original.value; node.checked = original.checked; node.indeterminate = original.indeterminate
    } else if (node instanceof HTMLTextAreaElement && original instanceof HTMLTextAreaElement) node.value = original.value
    else if (node instanceof HTMLSelectElement && original instanceof HTMLSelectElement) {
      Array.from(node.options).forEach((option, at) => { option.selected = original.options[at].selected })
    }
  })
  if (copy) {
    copy.inert = true
    copy.setAttribute('inert', '')
    copy.setAttribute('aria-hidden', 'true')
    copy.setAttribute('data-dialog-exit-copy', '')
  }
  // A guarded close may decline. Never mark, fade or disable that live panel.
  done()
  if (!copy || panel!.isConnected || !parent!.isConnected) return noExit
  const copiedPanel = copyNodes[panelIndex]
  for (const node of [copy, copiedPanel]) {
    node.style.transition = 'none'
  }
  // Keep a newly queued dialog above the old visual, at the original sibling slot.
  parent!.insertBefore(copy, parent!.childNodes[position] ?? null)
  copyNodes.forEach((node, index) => { [node.scrollLeft, node.scrollTop] = scroll[index] })
  const animations = [
    copiedPanel.animate([from!, { opacity: 0, transform: reduced ? from!.transform : window.innerWidth <= 620 ? 'translateY(100%)' : 'translateY(12px) scale(0.98)' }], { duration: 150, easing: 'cubic-bezier(0.23, 1, 0.32, 1)', fill: 'forwards' }),
    copy.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 150, easing: 'ease', fill: 'forwards' }),
  ]
  let finished = false
  const finish = () => {
    if (finished) return
    finished = true
    window.clearTimeout(deadline)
    animations.forEach(animation => animation.cancel())
    copy.remove()
    exits.delete(panel!)
  }
  const deadline = window.setTimeout(finish, 200)
  exits.set(panel!, finish)
  void Promise.allSettled(animations.map(animation => animation.finished)).then(finish)
  return finish
}
