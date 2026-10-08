// @vitest-environment jsdom
import { useEffect } from 'react'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { AuthProvider } from './AuthContext'
import { useAuthContext } from './authContextValue'
import App from '../App'
import { AccountMenu } from '../components/AccountMenu'
const clientId = 'client_FICTIONAL1'
const browserSession = { client_id: clientId, user: { id: 'workos-subject', email: 'fictional@pilot.test', first_name: 'Fictional', last_name: 'Person' }, organization_id: 'org_FICTIONAL1', authentication_method: 'SSO', access_token: 'short-lived-access-token', expires_at: new Date(Date.now() + 120_000).toISOString() }
const fetchMock = vi.fn()
function Probe() {
  const auth = useAuthContext()
  return <><p>{auth.currentUser ? 'Verified WorkOS account' : 'Closed workspace'}</p><p>{auth.authError}</p><span data-testid="status">{auth.authErrorStatus}</span>
    <button onClick={() => void auth.refreshCurrentUser()}>Check access</button></>
}
beforeEach(() => {
  fetchMock.mockReset(); vi.stubGlobal('fetch', fetchMock)
  fetchMock.mockImplementation(async input => String(input).endsWith('/api/auth/session') ? Response.json(browserSession) : Response.json({ user: { id: 17, clerk_id: 'legacy-clerk', auth_provider: 'workos', auth_subject: 'workos-subject' } }))
})
afterEach(() => { cleanup(); vi.unstubAllGlobals(); window.history.replaceState(null, '', '/') })
it('verifies the server session subject against permanent Rails identity and uses bearer finance transport', async () => {
  render(<AuthProvider provider="workos" clientId={clientId}><Probe /></AuthProvider>)
  await screen.findByText('Verified WorkOS account')
  const apiCall = fetchMock.mock.calls.find(([input]) => String(input).endsWith('/api/v1/auth/me'))!
  expect(apiCall[1].headers.Authorization).toBe('Bearer short-lived-access-token')
  expect(localStorage.getItem('workos_refresh_token')).toBeNull()
})
it('withholds the workspace on transient session outage and succeeds with bounded retry', async () => {
  fetchMock.mockResolvedValueOnce(Response.json({}, { status: 503 }))
  render(<AuthProvider provider="workos" clientId={clientId}><Probe /></AuthProvider>)
  await screen.findByText('Secure sign-in is temporarily unavailable. Try again in a moment.')
  expect(screen.getByTestId('status').textContent).toBe('503')
  expect(screen.getByText('Closed workspace')).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: 'Check access' }))
  await screen.findByText('Verified WorkOS account')
})
it('closes a verified workspace immediately on revoked session signal', async () => {
  render(<AuthProvider provider="workos" clientId={clientId}><Probe /></AuthProvider>)
  await screen.findByText('Verified WorkOS account')
  await act(async () => window.dispatchEvent(new Event('household-cfo:auth-expired')))
  await waitFor(() => expect(screen.queryByText('Verified WorkOS account')).toBeNull())
  expect(screen.getByTestId('status').textContent).toBe('401')
})

it('retries initial BFF outage without identity and verifies Rails access before any financial workspace request', async () => {
  fetchMock.mockResolvedValueOnce(Response.json({}, { status: 503 }))
  render(<AuthProvider provider="workos" clientId={clientId}><App /></AuthProvider>)
  await screen.findByRole('heading', { name: 'Secure access is temporarily unavailable.' })
  expect(fetchMock.mock.calls.some(([input]) => String(input).endsWith('/api/v1/auth/me'))).toBe(false)
  expect(screen.queryByText('$0')).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: 'Check access again' }))
  await waitFor(() => expect(fetchMock.mock.calls.some(([input]) => String(input).endsWith('/api/v1/auth/me'))).toBe(true))
  const apiCall = fetchMock.mock.calls.find(([input]) => String(input).endsWith('/api/v1/auth/me'))!
  expect(apiCall[1].headers.Authorization).toBe('Bearer short-lived-access-token')
})

it('offers App recovery after an atomic logout conflict and verifies the new cookie actor without sign-in', async () => {
  let other = false
  const expire = vi.fn()
  window.addEventListener('household-cfo:auth-expired', expire)
  fetchMock.mockImplementation(async input => {
    const path = String(input)
    if (path.endsWith('/api/auth/logout')) { other = true; return Response.json({ code: 'account_changed' }, { status: 409 }) }
    if (path.endsWith('/api/auth/session')) return Response.json(other ? { ...browserSession, user: { ...browserSession.user, id: 'other-subject' }, access_token: 'new-account-token' } : browserSession)
    if (path.endsWith('/api/v1/auth/me')) return Response.json({ user: { id: other ? 18 : 17, clerk_id: 'legacy-clerk', auth_provider: 'workos', auth_subject: other ? 'other-subject' : 'workos-subject', full_name: other ? 'Other fictional account' : 'Original fictional account' } })
    throw new Error(`Unexpected private request: ${path}`)
  })
  function Workspace() {
    const auth = useAuthContext()
    return auth.authError ? <App /> : <><p>{auth.currentUser?.full_name}</p><AccountMenu /></>
  }
  try {
    render(<AuthProvider provider="workos" clientId={clientId}><Workspace /></AuthProvider>)
    await waitFor(() => expect(screen.getAllByText('Original fictional account').length).toBeGreaterThan(0))
    fireEvent.click(screen.getByLabelText('Account and help'))
    fireEvent.click(screen.getByRole('button', { name: 'Sign out' }))
    await screen.findByRole('heading', { name: 'We couldn’t finish checking your access.' })
    expect(screen.queryByText('Original fictional account')).toBeNull()
    expect(screen.queryByRole('button', { name: 'Sign in again' })).toBeNull()
    expect(expire).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Check access again' }))
    await waitFor(() => expect(screen.getAllByText('Other fictional account').length).toBeGreaterThan(0))
    const calls = fetchMock.mock.calls.filter(([input]) => String(input).endsWith('/api/v1/auth/me'))
    expect(calls).toHaveLength(2)
    expect(calls[1][1].headers.Authorization).toBe('Bearer new-account-token')
    expect(fetchMock.mock.calls.filter(([input]) => String(input).endsWith('/api/auth/logout'))).toHaveLength(1)
    expect(fetchMock.mock.calls.some(([input]) => String(input).endsWith('/api/auth/login'))).toBe(false)
  } finally { window.removeEventListener('household-cfo:auth-expired', expire) }
})

it('opens in-app sign-in and verifies the same permanent account without a hosted redirect', async () => {
  let signedIn = false
  let codeAttempts = 0
  fetchMock.mockImplementation(async input => {
    const path = String(input)
    if (path.endsWith('/api/auth/session')) return Response.json(signedIn ? browserSession : { client_id: clientId, user: null })
    if (path.endsWith('/api/auth/options')) return Response.json({ google_enabled: false })
    if (path.endsWith('/api/auth/email/start')) return Response.json({ step: 'code', challenge_id: 'e'.repeat(43), email: 'fictional@pilot.test', expires_at: new Date(Date.now() + 600_000).toISOString(), resend_after: 60 })
    if (path.endsWith('/api/auth/email/verify')) {
      if (++codeAttempts === 1) return Response.json({ code: 'email_code_invalid' }, { status: 401 })
      signedIn = true
      return Response.json({ step: 'complete', return_to: `${window.location.origin}/` })
    }
    if (path.endsWith('/api/v1/auth/me')) return Response.json({ user: { id: 17, auth_provider: 'workos', auth_subject: 'workos-subject', role: 'participant' } })
    throw new Error('Unexpected auth transport')
  })
  function FrontDoor() {
    const auth = useAuthContext()
    return <><Probe /><button onClick={() => void auth.signIn?.()}>Open sign-in dialog</button></>
  }
  render(<AuthProvider provider="workos" clientId={clientId}><FrontDoor /></AuthProvider>)
  await waitFor(() => expect(fetchMock).toHaveBeenCalled())
  fireEvent.click(screen.getByRole('button', { name: 'Open sign-in dialog' }))
  await screen.findByRole('dialog')
  fireEvent.change(screen.getByLabelText('Email address'), { target: { value: 'fictional@pilot.test' } })
  fireEvent.click(screen.getByRole('button', { name: 'Continue with email' }))
  const code = await screen.findByLabelText('Sign-in code')
  fireEvent.change(code, { target: { value: '123456' } })
  fireEvent.click(screen.getByRole('button', { name: 'Verify and sign in' }))
  await screen.findByText('That code did not match. Check the latest email and try again.')
  expect(screen.getByText('Closed workspace')).toBeTruthy()
  fireEvent.change(code, { target: { value: '654321' } })
  fireEvent.click(screen.getByRole('button', { name: 'Verify and sign in' }))
  await screen.findByText('Verified WorkOS account')
  expect(screen.queryByRole('dialog')).toBeNull()
  expect(fetchMock.mock.calls.some(([input]) => String(input).endsWith('/api/auth/login'))).toBe(false)
})

it('refreshes a completed cookie after explicit cancellation without dismissing the newer email flow', async () => {
  const popup = { close: vi.fn(), closed: false, location: { href: 'about:blank' } }
  vi.stubGlobal('open', vi.fn().mockReturnValue(popup))
  vi.stubGlobal('matchMedia', () => ({ matches: true }))
  let signedIn = false
  let finishCancellation: ((response: Response) => void) | undefined
  const authorize = new URL('https://api.workos.com/user_management/authorize')
  authorize.searchParams.set('client_id', clientId)
  authorize.searchParams.set('redirect_uri', `${window.location.origin}/api/auth/callback`)
  authorize.searchParams.set('state', 's'.repeat(43))
  fetchMock.mockImplementation(async input => {
    const path = String(input)
    if (path.endsWith('/api/auth/session')) return Response.json(signedIn ? browserSession : { client_id: clientId, user: null })
    if (path.endsWith('/api/auth/options')) return Response.json({ google_enabled: true })
    if (path.endsWith('/api/auth/login')) return Response.json({ authorization_url: authorize.href })
    if (path.endsWith('/api/auth/login/status')) return Response.json({ status: 'pending' })
    if (path.endsWith('/api/auth/login/cancel')) return new Promise<Response>(resolve => { finishCancellation = resolve })
    if (path.endsWith('/api/v1/auth/me')) return Response.json({ user: { id: 17, auth_provider: 'workos', auth_subject: 'workos-subject' } })
    throw new Error('Unexpected fictional transport')
  })
  function Entry() {
    const auth = useAuthContext()
    return <><Probe /><button onClick={() => void auth.signIn?.()}>Open sign-in dialog</button></>
  }
  render(<AuthProvider provider="workos" clientId={clientId}><Entry /></AuthProvider>)
  fireEvent.click(screen.getByRole('button', { name: 'Open sign-in dialog' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Continue with Google' }))
  await waitFor(() => expect(popup.location.href).toBe(authorize.href))
  fireEvent.click(screen.getByRole('button', { name: 'Cancel sign-in' }))
  await waitFor(() => expect(finishCancellation).toBeTypeOf('function'))
  fireEvent.change(screen.getByLabelText('Email address'), { target: { value: 'new-invited@pilot.test' } })
  signedIn = true
  await act(async () => { finishCancellation!(Response.json({ status: 'complete' })) })
  await screen.findByText('Verified WorkOS account')
  expect(screen.getByRole('dialog')).toBeTruthy()
  expect(screen.getByLabelText('Email address')).toHaveProperty('value', 'new-invited@pilot.test')
})

it('loads the cookie while branding is pending, gates actor verification, and re-verifies after readiness is lost',async()=>{
 let retained:(()=>Promise<void>)|undefined;
 function RetainProbe(){const auth=useAuthContext();useEffect(()=>{if(auth.currentUser)retained=auth.refreshCurrentUser},[auth.currentUser,auth.refreshCurrentUser]);return <Probe/>}
 const view=render(<AuthProvider provider="workos" clientId={clientId} verificationEnabled={false}><RetainProbe/></AuthProvider>);
 await waitFor(()=>expect(fetchMock).toHaveBeenCalled());const actorReads=()=>fetchMock.mock.calls.filter(([input])=>String(input).endsWith('/api/v1/auth/me')).length;
 expect(actorReads()).toBe(0);expect(screen.queryByText('Verified WorkOS account')).toBeNull();
 view.rerender(<AuthProvider provider="workos" clientId={clientId}><RetainProbe/></AuthProvider>);await screen.findByText('Verified WorkOS account');expect(actorReads()).toBe(1);const previous=retained!;
 view.rerender(<AuthProvider provider="workos" clientId={clientId} verificationEnabled={false}><RetainProbe/></AuthProvider>);expect(screen.queryByText('Verified WorkOS account')).toBeNull();await act(async()=>previous());expect(actorReads()).toBe(1);
 view.rerender(<AuthProvider provider="workos" clientId={clientId}><RetainProbe/></AuthProvider>);await screen.findByText('Verified WorkOS account');expect(actorReads()).toBe(2);
})
it('ignores a late actor response after program approval disappears',async()=>{
 let finish:((response:Response)=>void)|undefined;let signal:AbortSignal|undefined;
 fetchMock.mockImplementation(async(input,options)=>String(input).endsWith('/api/auth/session')?Response.json(browserSession):new Promise<Response>(resolve=>{finish=resolve;signal=options.signal}));
 const view=render(<AuthProvider provider="workos" clientId={clientId}><Probe/></AuthProvider>);await waitFor(()=>expect(finish).toBeTypeOf('function'));
 view.rerender(<AuthProvider provider="workos" clientId={clientId} verificationEnabled={false}><Probe/></AuthProvider>);expect(signal?.aborted).toBe(true);
 await act(async()=>finish!(Response.json({user:{id:17,auth_provider:'workos',auth_subject:'workos-subject'}})));expect(screen.queryByText('Verified WorkOS account')).toBeNull();
})
