import { ApiRequestError } from '../api'

const OFFLINE_MESSAGE = 'Your workspace is offline for a moment. Check your connection and try again.'

/**
 * Turns a workspace load failure into participant-facing copy. Authentication
 * and server faults carry internal wording, so they get fixed messages; other
 * API errors already speak to the participant and pass through unchanged.
 */
export function workspaceLoadMessage(caught: unknown): string {
  if (caught instanceof ApiRequestError) {
    if (caught.status === 401) return 'Your sign-in has ended. Sign in again to open your workspace.'
    if (caught.status >= 500) return 'Your workspace is having trouble loading. Try again in a moment.'
    return caught.message || OFFLINE_MESSAGE
  }
  return OFFLINE_MESSAGE
}
