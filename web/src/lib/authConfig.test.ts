import { describe, expect, it } from 'vitest'
import { authConfiguration } from './authConfig'
describe('server-managed auth provider configuration', () => {
  it('keeps Clerk as the production transition default and fails closed without its configuration', () => {
    expect(authConfiguration({ PROD: true }, 'cfo.example.com')).toMatchObject({ provider: 'clerk', error: expect.any(String) })
    expect(authConfiguration({ PROD: true, VITE_CLERK_PUBLISHABLE_KEY: 'pk_live_valid' }, 'cfo.example.com')).toMatchObject({ provider: 'clerk', error: null })
  })
  it.each(['localhost', 'householdcfomethod.com', 'company-brand.test', 'preview.netlify.app'])('uses free same-origin server sessions on %s without a paid API domain or browser refresh storage', hostname => {
    expect(authConfiguration({ VITE_AUTH_PROVIDER: 'workos', VITE_WORKOS_CLIENT_ID: 'client_FICTIONAL1', PROD: true }, hostname)).toEqual({ provider: 'workos', clientId: 'client_FICTIONAL1', devMode: false, error: null })
  })
  it.each(['', 'bad-client', 'client_'])('rejects missing or invalid expected public client ID %s', client => {
    expect(authConfiguration({ VITE_AUTH_PROVIDER: 'workos', VITE_WORKOS_CLIENT_ID: client }, 'localhost').error).toBeTruthy()
  })
  it('never enables refresh-token browser storage even in development', () => {
    expect(authConfiguration({ VITE_AUTH_PROVIDER: 'workos', VITE_WORKOS_CLIENT_ID: 'client_FICTIONAL1', DEV: true }, 'localhost').devMode).toBe(false)
  })
  it('permits no-auth preview only on loopback development with Clerk unconfigured', () => {
    expect(authConfiguration({ DEV: true }, 'localhost').provider).toBe('preview')
    expect(authConfiguration({ DEV: true }, '0.0.0.0').error).toBeTruthy()
    expect(authConfiguration({ VITE_AUTH_PROVIDER: 'invalid', DEV: true }, 'localhost').error).toBeTruthy()
  })
})
