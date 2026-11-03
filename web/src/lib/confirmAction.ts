// The app's own confirmation, in place of the browser's grey window.confirm.
// ConfirmHost (mounted once in the workspace) shows it. Where no host is
// mounted, such as an isolated component, it falls back to the browser prompt so
// the answer is never silently "yes".
export type ConfirmOptions = {
  title?: string
  confirmLabel?: string
  cancelLabel?: string
  /** Shows the confirm action as a caution (delete, disconnect, discard). */
  caution?: boolean
}

export type ConfirmRequest = ConfirmOptions & { message: string; resolve: (confirmed: boolean) => void }

let host: ((request: ConfirmRequest) => void) | null = null

export function registerConfirmHost(show: (request: ConfirmRequest) => void) {
  host = show
  return () => {
    if (host === show) host = null
  }
}

export function confirmAction(message: string, options: ConfirmOptions = {}): Promise<boolean> {
  if (!host) return Promise.resolve(window.confirm(message))
  const show = host
  return new Promise((resolve) => show({ ...options, message, resolve }))
}

/** Leaving a screen with changes that are not saved yet. */
export function confirmDiscard(message: string, options: ConfirmOptions = {}) {
  return confirmAction(message, { title: 'Leave without saving?', confirmLabel: 'Discard changes', cancelLabel: 'Keep editing', caution: true, ...options })
}
