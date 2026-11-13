// More and dialogs can overlap and close in either order during one Escape.
// Only the last owner restores the body's original inline overflow.
const owners = new Set<symbol>()
let previousOverflow = ''

export function lockBodyScroll() {
  const token = Symbol('body-scroll-lock')
  if (owners.size === 0) previousOverflow = document.body.style.overflow
  owners.add(token)
  document.body.style.overflow = 'hidden'
  return () => {
    if (!owners.delete(token)) return
    if (owners.size === 0) document.body.style.overflow = previousOverflow
  }
}
