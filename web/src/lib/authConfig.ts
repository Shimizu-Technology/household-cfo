export type AuthProviderName = 'clerk' | 'workos'
export type AuthConfiguration = { provider: AuthProviderName | 'preview'; error: string | null; clientId?: string; apiHostname?: string; clerkKey?: string; devMode: boolean }

export function authConfiguration(env: Record<string, unknown>, hostname: string): AuthConfiguration {
  const provider = env.VITE_AUTH_PROVIDER || 'clerk'
  const localDevelopment = env.DEV === true && ['localhost', '127.0.0.1', '[::1]'].includes(hostname)
  const base = { provider: 'clerk' as const, error: null, devMode: false }
  if (provider !== 'clerk' && provider !== 'workos') return { ...base, error: 'Secure sign-in is unavailable. Please contact your program support team.' }
  if (provider === 'workos') {
    const clientId = String(env.VITE_WORKOS_CLIENT_ID || '').trim()
    if (!/^client_[A-Za-z0-9]+$/.test(clientId)) {
      return { provider, error: 'Secure sign-in is unavailable. Please contact your program support team.', devMode: false }
    }
    // Rails owns the refresh session behind same-origin /api/auth endpoints.
    // No paid authentication API domain or browser token storage is required.
    return { provider, clientId, devMode: false, error: null }
  }
  const clerkKey = String(env.VITE_CLERK_PUBLISHABLE_KEY || '').trim()
  if (!clerkKey || ['pk_test_xxx', 'pk_test_dummy', 'your_clerk_publishable_key', 'YOUR_PUBLISHABLE_KEY'].includes(clerkKey)) {
    return localDevelopment ? { ...base, provider: 'preview' } : { ...base, error: 'Secure sign-in is unavailable. Please contact your program support team.' }
  }
  return { ...base, clerkKey }
}
