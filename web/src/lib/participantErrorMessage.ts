// Structural match for the API client's ApiRequestError, so this helper has no
// runtime dependency on the API module (and works where tests mock it).
type ApiErrorLike = Error & { status: number; code?: string | null }
function isApiError(caught: unknown): caught is ApiErrorLike {
  return caught instanceof Error && caught.name === 'ApiRequestError' && typeof (caught as { status?: unknown }).status === 'number'
}

const CODE_MESSAGES: Record<string, string> = {
  financial_generation_stale: 'Something changed since this page loaded. Refresh and try again. Nothing was saved.',
  savings_review_conflict: 'This record changed since you opened it. Refresh to see the latest, then try again.',
  rate_limited: 'You’re going a little fast. Give it a minute and try again.',
  savings_challenge_unavailable: 'This part of your program isn’t available right now. Contact your program team if that seems wrong.',
  module_disabled: 'This tool isn’t turned on for your program.',
  storage_unavailable: 'Uploads are unavailable for a moment. Try again in a few minutes.',
}

const STATUS_MESSAGES: Record<number, string> = {
  401: 'Your sign-in has ended. Sign in again to continue.',
  403: 'Your account doesn’t have access to this. Contact your program team if that seems wrong.',
  404: 'We couldn’t find that anymore. Refresh to see the latest.',
  409: 'This changed since you opened it. Refresh to see the latest, then try again.',
  413: 'That file is too large. Try a smaller file or a screenshot.',
  429: 'You’re going a little fast. Give it a minute and try again.',
}

// Server text for these is never needed to act; the fixed sentence is clearer.
const FIXED_STATUSES = new Set([401, 404, 413, 429])

const SERVER_MESSAGE = 'Something went wrong on our side. Your information is safe. Try again in a few minutes.'
const CONNECTION_MESSAGE = 'We couldn’t reach the server. Check your connection and try again.'

// Wording that belongs to engineers, not participants. A message containing any of
// these falls back to the caller's plain sentence.
const TECHNICAL = /\b(api|request (identity|identifier|key|reference)|idempoten|integer cents|canonical|digest|lease|provenance|linkage|payload|json|schema|null|undefined|token|uuid|endpoint|status \d{3}|failed: \d{3}|exception|stack|nil)\b/i

/**
 * Turns any error a participant can hit into calm, plain copy. API errors are
 * mapped by code, then status; human-written messages (validation, guidance
 * written in this app) pass through; technical or empty text uses the fallback.
 * Admin and coach tools keep their detailed messages and do not use this.
 */
export function participantErrorMessage(caught: unknown, fallback: string): string {
  if (isApiError(caught)) {
    if (caught.code && CODE_MESSAGES[caught.code]) return CODE_MESSAGES[caught.code]
    if (caught.status >= 500) return SERVER_MESSAGE
    if (FIXED_STATUSES.has(caught.status)) return STATUS_MESSAGES[caught.status]
    return readable(caught.message) ? caught.message : STATUS_MESSAGES[caught.status] ?? fallback
  }
  if (!(caught instanceof Error)) return fallback
  if (caught.name === 'AbortError') return fallback
  if (/could not reach the server|failed to fetch|network ?error|load failed/i.test(caught.message)) return CONNECTION_MESSAGE
  return readable(caught.message) ? caught.message : fallback
}

function readable(message: string | undefined): message is string {
  const text = message?.trim()
  return Boolean(text) && !TECHNICAL.test(text!)
}
