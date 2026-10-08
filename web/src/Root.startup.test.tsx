// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useEffect } from 'react'
import Root from './Root'
import { BrandProvider } from './contexts/BrandContext'
import { useAuthContext } from './contexts/authContextValue'
import { NEUTRAL_BRAND, useBrand } from './contexts/brandContextValue'
import { WorkspaceOpening } from './components/WorkspaceOpening'

const testState = vi.hoisted(() => ({ hostname: '', privateMount: vi.fn() }))
vi.mock('./lib/authConfig', () => ({ authConfiguration: () => ({ provider: 'workos', error: null, clientId: 'client_FICTIONAL1' }) }))
vi.mock('./api', async importOriginal => ({ ...await importOriginal<typeof import('./api')>(), browserBrandHostname: () => testState.hostname }))
vi.mock('./providers/PostHogProvider', () => ({ PostHogProvider: ({ children }: { children: React.ReactNode }) => children }))
vi.mock('./App', () => ({ default: StartupTestApp }))

function PrivateWorkspace() {
  useEffect(() => { testState.privateMount() }, [])
  return <h1>Verified private fixture</h1>
}
function StartupTestApp() {
  const auth = useAuthContext()
  if (auth.authError) return <p role="alert">{auth.authError}</p>
  if (auth.isLoading || auth.isVerifyingApi) return <WorkspaceOpening status="Signing you in securely…" />
  return auth.currentUser ? <PrivateWorkspace /> : <h1>Signed out fixture</h1>
}
function RetryProgram() {
  const { retry } = useBrand()
  return <button onClick={retry}>Recheck fixture program</button>
}
const session = { client_id: 'client_FICTIONAL1', user: { id: 'user_FICTIONAL1', email: 'fictional@pilot.test' }, organization_id: 'org_FICTIONAL1', authentication_method: 'GoogleOAuth', access_token: 'fictional-token', expires_at: new Date(Date.now() + 3600000).toISOString() }
const user = { id: 901, auth_provider: 'workos', auth_subject: 'user_FICTIONAL1', full_name: 'Fictional Participant', role: 'participant' }
const brand = () => Response.json({ brand: { ...NEUTRAL_BRAND, organization_name: 'Fictional startup' }, available: true, source: 'qa' })
let sequence = 0
beforeEach(() => { testState.hostname = `startup-${++sequence}.test`; testState.privateMount.mockClear() })
afterEach(() => { cleanup(); vi.unstubAllGlobals(); vi.useRealTimers() })
function requestPath(input: RequestInfo | URL) { return new URL(input instanceof Request ? input.url : String(input), window.location.href).pathname }

describe('Root startup authentication ordering', () => {
  it('starts branding and cookie reads concurrently but waits for approved branding before Rails actor and private mount', async () => {
    let resolveBrand!: (response: Response) => void
    let resolveActor!: (response: Response) => void
    const calls: string[] = []
    vi.stubGlobal('fetch', vi.fn((input: RequestInfo | URL) => {
      const path = requestPath(input); calls.push(path)
      if (path === '/api/public/brand') return new Promise<Response>(resolve => { resolveBrand = resolve })
      if (path === '/api/auth/session') return Promise.resolve(Response.json(session))
      if (path === '/api/v1/auth/me') return new Promise<Response>(resolve => { resolveActor = resolve })
      throw new Error(`Unexpected request ${path}`)
    }))
    render(<BrandProvider><Root /></BrandProvider>)
    await waitFor(() => expect(calls).toContain('/api/auth/session'))
    expect(calls).toContain('/api/public/brand')
    expect(calls).not.toContain('/api/v1/auth/me')
    expect(testState.privateMount).not.toHaveBeenCalled()
    expect(screen.getByRole('heading', { name: 'Opening your workspace…' })).toBeTruthy()
    expect(screen.queryByRole('button', { name: /reload|try again/i })).toBeNull()
    await act(async () => resolveBrand(brand()))
    await waitFor(() => expect(calls).toContain('/api/v1/auth/me'))
    expect(screen.getByRole('heading', { name: 'Opening your workspace…' })).toBeTruthy()
    expect(screen.getByRole('status').textContent).toBe('Signing you in securely…')
    expect(testState.privateMount).not.toHaveBeenCalled()
    await act(async () => resolveActor(Response.json({ user })))
    await screen.findByRole('heading', { name: 'Verified private fixture' })
    expect(calls.filter(path => path === '/api/v1/auth/me')).toHaveLength(1)
    expect(calls.filter(path => path === '/api/auth/session')).toHaveLength(2)
    expect(testState.privateMount).toHaveBeenCalledTimes(1)
  })

  it('withdraws an already verified workspace immediately when program approval is rechecked and lost', async () => {
    let brandAttempts = 0
    let resolveLostBrand!: (response: Response) => void
    let actorCalls = 0
    vi.stubGlobal('fetch', vi.fn((input: RequestInfo | URL) => {
      const path = requestPath(input)
      if (path === '/api/public/brand') return ++brandAttempts === 1 ? Promise.resolve(brand()) : new Promise<Response>(resolve => { resolveLostBrand = resolve })
      if (path === '/api/auth/session') return Promise.resolve(Response.json(session))
      if (path === '/api/v1/auth/me') { actorCalls++; return Promise.resolve(Response.json({ user })) }
      throw new Error(`Unexpected request ${path}`)
    }))
    render(<BrandProvider><RetryProgram /><Root /></BrandProvider>)
    await screen.findByRole('heading', { name: 'Verified private fixture' })
    fireEvent.click(screen.getByRole('button', { name: 'Recheck fixture program' }))
    expect(screen.queryByRole('heading', { name: 'Verified private fixture' })).toBeNull()
    expect(screen.getByRole('heading', { name: 'Opening your workspace…' })).toBeTruthy()
    await act(async () => resolveLostBrand(Response.json({ brand: NEUTRAL_BRAND, available: false, source: 'safe_default' }, { status: 404 })))
    await screen.findByRole('heading', { name: 'This program link is not available' })
    expect(actorCalls).toBe(1)
    expect(testState.privateMount).toHaveBeenCalledTimes(1)
  })

  for (const unavailable of [false, true]) {
    it(`keeps signed-in private content closed when public branding is ${unavailable ? 'unavailable' : 'failed'} and recovers through explicit retry`, async () => {
      let attempts = 0
      let actorCalls = 0
      vi.stubGlobal('fetch', vi.fn((input: RequestInfo | URL) => {
        const path = requestPath(input)
        if (path === '/api/public/brand') return Promise.resolve(++attempts === 1 ? unavailable ? Response.json({ brand: NEUTRAL_BRAND, source: 'safe_default', available: false }, { status: 404 }) : Response.json({}, { status: 503 }) : brand())
        if (path === '/api/auth/session') return Promise.resolve(Response.json(session))
        if (path === '/api/v1/auth/me') { actorCalls++; return Promise.resolve(Response.json({ user })) }
        throw new Error(`Unexpected request ${path}`)
      }))
      render(<BrandProvider><Root /></BrandProvider>)
      await screen.findByRole('heading', { name: unavailable ? 'This program link is not available' : 'Your program could not load' })
      expect(actorCalls).toBe(0)
      expect(testState.privateMount).not.toHaveBeenCalled()
      fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
      await screen.findByRole('heading', { name: 'Verified private fixture' })
      expect(actorCalls).toBe(1)
      expect(attempts).toBe(2)
    })
  }
})
