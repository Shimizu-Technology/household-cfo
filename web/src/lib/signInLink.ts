const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]'])

// The API reports the sign-in link from its own configuration. In local or
// preview setups that points at a different port than the page the coach is
// actually using, so a loopback address from the API is replaced by this page's
// origin. A real (non-loopback) program domain from the API is kept.
export function shareableSignInUrl(apiUrl: string | null | undefined, pageOrigin: string = window.location.origin): string | null {
  if (!apiUrl) return null
  try {
    const parsed = new URL(apiUrl)
    const page = new URL(pageOrigin)
    if (LOCAL_HOSTS.has(parsed.hostname) && LOCAL_HOSTS.has(page.hostname)) return page.origin
    return apiUrl
  } catch {
    return apiUrl
  }
}
