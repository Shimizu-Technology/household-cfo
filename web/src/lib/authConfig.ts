export type AuthProviderName = 'workos'
export type AuthConfiguration = { provider: AuthProviderName | 'preview'; error: string | null; clientId?: string; devMode: boolean }

const unavailable = 'Secure sign-in is unavailable. Please contact your program support team.'

// WorkOS is the only sign-in provider. Local development without a WorkOS client
// falls back to the sample-data preview; every other incomplete setup fails closed.
export function authConfiguration(env: Record<string, unknown>, hostname: string): AuthConfiguration {
  const selected = env.VITE_AUTH_PROVIDER
  const localDevelopment = env.DEV === true && ['localhost', '127.0.0.1', '[::1]'].includes(hostname)
  if (selected && selected !== 'workos') return { provider: 'workos', error: unavailable, devMode: false }
  const clientId = String(env.VITE_WORKOS_CLIENT_ID || '').trim()
  if (/^client_[A-Za-z0-9]+$/.test(clientId)) {
    // Rails owns the refresh session behind same-origin /api/auth endpoints.
    // No paid authentication API domain or browser token storage is required.
    return { provider: 'workos', clientId, devMode: false, error: null }
  }
  if (!selected && localDevelopment) return { provider: 'preview', error: null, devMode: false }
  return { provider: 'workos', error: unavailable, devMode: false }
}
