// Invitations are credentials. Keep them out of visible URLs, analytics and
// plaintext OAuth navigation state; the SDK receives the opaque token directly.
export function captureAuthInvitation(): { token: string | null; error: string | null } {
  if (typeof window === 'undefined') return { token: null, error: null }
  const url = new URL(window.location.href)
  const values = url.searchParams.getAll('invitation_token')
  if (!values.length) return { token: null, error: null }
  url.searchParams.delete('invitation_token')
  window.history.replaceState(null, '', `${url.pathname}${url.search}${url.hash}`)
  const token = values[0]
  const invalidCharacter = Array.from(token ?? '').some(character => character.charCodeAt(0) < 32 || character.charCodeAt(0) === 127 || /\s/.test(character))
  if (values.length !== 1 || !['/', '/login'].includes(url.pathname) || !token || token.length > 4096 || invalidCharacter) {
    return { token: null, error: 'This invitation link could not be verified. Ask your program administrator to resend it.' }
  }
  return { token, error: null }
}
