export type AuthProviderName = 'clerk' | 'workos'
export type AuthConfiguration = { provider: AuthProviderName | 'preview'; error: string | null; clientId?: string; apiHostname?: string; clerkKey?: string; devMode: boolean }

export function authConfiguration(env: Record<string, unknown>, hostname: string): AuthConfiguration {
  const provider = env.VITE_AUTH_PROVIDER || 'clerk'
  const localDevelopment = env.DEV === true && ['localhost', '127.0.0.1', '[::1]'].includes(hostname)
  const base = { provider: 'clerk' as const, error: null, devMode: false }
  if (provider !== 'clerk' && provider !== 'workos') return { ...base, error: 'Secure sign-in is unavailable. Please contact your program support team.' }
  if (provider === 'workos') {
    const clientId = String(env.VITE_WORKOS_CLIENT_ID || '').trim()
    const apiHostname = String(env.VITE_WORKOS_API_HOSTNAME || '').trim()
    const validHostname = /^[a-z0-9]+(?:[.-][a-z0-9]+)*\.[a-z]{2,}$/i.test(apiHostname)
    if (!/^client_[A-Za-z0-9]+$/.test(clientId) || (apiHostname && !validHostname) || (!localDevelopment && (!validHostname || apiHostname === 'api.workos.com'))) {
      return { provider, error: 'Secure sign-in is unavailable. Please contact your program support team.', devMode: false }
    }
    return { provider, clientId, apiHostname: apiHostname || undefined, devMode: localDevelopment, error: null }
  }
  const clerkKey = String(env.VITE_CLERK_PUBLISHABLE_KEY || '').trim()
  if (!clerkKey || ['pk_test_xxx', 'pk_test_dummy', 'your_clerk_publishable_key', 'YOUR_PUBLISHABLE_KEY'].includes(clerkKey)) {
    return localDevelopment ? { ...base, provider: 'preview' } : { ...base, error: 'Secure sign-in is unavailable. Please contact your program support team.' }
  }
  return { ...base, clerkKey }
}
