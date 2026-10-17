import type { MiaMessage } from '../api'

// A reply the server did not save (conversation_persisted === false), such as "your challenge
// isn't open yet", exists only in this browser. Polling replaces history with the server's
// copy, so these stay visible until the participant clears the view, leaves the program, or
// the challenge opens (keep = false). Clearing the view while the challenge is closed only
// needs the server when something saved is shown (see onlyLocalMessages); otherwise the
// server's clear is refused for a closed challenge, so it is done in the browser.
export function markLocalOnly(messages: MiaMessage[]): MiaMessage[] {
  return messages.map((message) => ({ ...message, local_only: true, client_id: message.client_id ?? `local-${message.role}-${Math.random().toString(36).slice(2)}` }))
}

export function keepLocalOnly(current: MiaMessage[], serverMessages: MiaMessage[], keep: boolean): MiaMessage[] {
  if (!keep) return serverMessages
  const local = current.filter((message) => message.local_only)
  return local.length ? [...serverMessages, ...local] : serverMessages
}

// True when everything shown exists only in this browser, so clearing needs no server call.
export function onlyLocalMessages(messages: MiaMessage[]): boolean {
  return messages.length > 0 && messages.every((message) => message.local_only)
}
