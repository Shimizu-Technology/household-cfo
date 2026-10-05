// Scroll the dialog itself so the browser cannot pan the background page.
export function revealDialogControl(element: HTMLElement, dialog: Element) {
  if (element === dialog || !(dialog instanceof HTMLElement)) return
  const panel = dialog.getBoundingClientRect()
  const control = element.getBoundingClientRect()
  const top = panel.top + dialog.clientTop
  const bottom = top + dialog.clientHeight
  if (control.top < top || control.height > dialog.clientHeight) {
    dialog.scrollTop += control.top - top
  } else if (control.bottom > bottom) {
    dialog.scrollTop += control.bottom - bottom
  }
}
