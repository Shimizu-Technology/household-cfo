import { ApiRequestError, type AppData } from '../api'

/** The server refused to confirm because the purchase looks like one she already has. Nothing counted; its card asks "Same purchase as …?". */
export function isPossibleDuplicateRefusal(caught: unknown) {
  return caught instanceof ApiRequestError && caught.code === 'possible_duplicate'
}

export type ConfirmAfterCreateOutcome =
  | { kind: 'confirmed'; workspace: AppData }
  // Waiting in Review, where its card asks "Same purchase as …?".
  | { kind: 'asking' }
  // Not known to have finished: it stays in Review, where Confirm uses the same key again.
  | { kind: 'unfinished' }

/**
 * Confirms a purchase that was just added. `confirm` must reuse one idempotency key on every call.
 * A lost response can hide a confirmation that went through, so a transport or server failure is
 * asked once more with that key: the server replays a finished confirmation and never counts the
 * purchase twice. A "Same purchase?" refusal on either attempt is answered on the card.
 */
export async function confirmAfterCreate(confirm: () => Promise<AppData>): Promise<ConfirmAfterCreateOutcome> {
  try {
    return { kind: 'confirmed', workspace: await confirm() }
  } catch (caught) {
    if (isPossibleDuplicateRefusal(caught)) return { kind: 'asking' }
    if (caught instanceof ApiRequestError && caught.status < 500) return { kind: 'unfinished' }
  }
  try {
    return { kind: 'confirmed', workspace: await confirm() }
  } catch (retryCaught) {
    return isPossibleDuplicateRefusal(retryCaught) ? { kind: 'asking' } : { kind: 'unfinished' }
  }
}

/**
 * Reloads what Review shows after a refused or out-of-date action. True only when every view she
 * may be looking at is current: the workspace, a selected budget year other than this one, and the
 * details of any receipt or statement whose purchase cards showed the action. Only then can a card
 * replace the refusal message with its question.
 */
export async function reloadReviewData(steps: {
  fetchLatest: () => Promise<AppData>
  isCurrent: () => boolean
  apply: (latest: AppData) => void
  restoreSelectedYear: (latest: AppData) => Promise<boolean>
  refreshDocuments: () => Promise<boolean>
}): Promise<boolean> {
  let latest: AppData
  try {
    latest = await steps.fetchLatest()
  } catch {
    return false
  }
  if (!steps.isCurrent()) return false
  steps.apply(latest)
  // Both run even if one fails, so as much as possible is current.
  const [yearCurrent, documentsCurrent] = await Promise.all([steps.restoreSelectedYear(latest), steps.refreshDocuments()])
  return yearCurrent && documentsCurrent
}
