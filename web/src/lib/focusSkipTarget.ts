import type { MouseEvent } from 'react'

// A skip link moves focus within the page without navigating or waking leave guards.
export function focusSkipTarget(event: MouseEvent<HTMLAnchorElement>) {
  event.preventDefault()
  const target = document.getElementById(event.currentTarget.hash.slice(1))
  if (!target) return
  if (!target.hasAttribute('tabindex')) {
    target.tabIndex = -1
    target.addEventListener('blur', () => target.removeAttribute('tabindex'), { once: true })
  }
  target.focus()
}
