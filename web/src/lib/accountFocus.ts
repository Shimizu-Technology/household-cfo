/** Chat hides its phone account summary when the disclosure closes. */
export function accountFocusTarget(menu: HTMLDetailsElement | null) {
  const summary = menu?.querySelector<HTMLElement>(':scope > summary')
  const more = menu?.closest('.participant-app')?.querySelector<HTMLElement>('.tabs-more-toggle')
  return summary?.getClientRects().length ? summary : more ?? summary
}

export function restoreAccountFocus(menu: HTMLDetailsElement | null) {
  accountFocusTarget(menu)?.focus({ preventScroll: true })
}
