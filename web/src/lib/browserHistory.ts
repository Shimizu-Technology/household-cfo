/** One position for every shell and nested Studio entry, including return visits. */
export function historyPosition(): number {
  const position: unknown = window.history.state?.appHistoryPosition
  if (typeof position === 'number') return position
  window.history.replaceState({ ...window.history.state, appHistoryPosition: 0 }, '')
  return 0
}

export function pushHistoryEntry(state: Record<string, unknown>, url: string | URL) {
  const position = historyPosition() + 1
  window.history.pushState({ ...state, appHistoryPosition: position }, '', url)
}
