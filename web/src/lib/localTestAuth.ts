/** A production-optimized QA build may use test identities only on loopback. */
export function isolatedLoopbackBuild(env: Record<string, unknown>, hostname: string) {
  if (env.VITE_LOCAL_STACK !== 'true' || env.VITE_E2E_AUTH !== 'true') return false
  try {
    const local = (host: string) => ['127.0.0.1', 'localhost', '[::1]'].includes(host)
    return local(hostname) && local(new URL(String(env.VITE_API_BASE_URL)).hostname)
  } catch { return false }
}
export function localTestAuth() {
  return import.meta.env.VITE_E2E_AUTH === 'true' && (import.meta.env.DEV || isolatedLoopbackBuild(import.meta.env, window.location.hostname))
}
