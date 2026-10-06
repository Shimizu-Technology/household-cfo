// Reveal the focused control inside the dialog's scrolling body, leaving its
// persistent header and the background page in place.
export function revealDialogControl(element: HTMLElement, dialog: Element) {
  if (element === dialog || !(dialog instanceof HTMLElement)) return
  const body = element.closest<HTMLElement>('.pilot-dialog-body, .mia-assist-body')
  const scroller = body && dialog.contains(body) ? body : dialog
  const panel = scroller.getBoundingClientRect()
  const control = element.getBoundingClientRect()
  const top = panel.top + scroller.clientTop
  const bottom = top + scroller.clientHeight
  if (control.top < top || control.height > scroller.clientHeight) {
    scroller.scrollTop += control.top - top
  } else if (control.bottom > bottom) {
    scroller.scrollTop += control.bottom - bottom
  }
}
