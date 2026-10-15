import { describe, expect, it } from 'vitest'
import { authConfiguration } from './authConfig'
describe('server-managed auth provider configuration', () => {
  it('uses WorkOS by default and fails closed in production without a client', () => {
    expect(authConfiguration({ PROD: true }, 'cfo.example.com')).toMatchObject({ provider: 'workos', error: expect.any(String) })
    expect(authConfiguration({ PROD: true, VITE_WORKOS_CLIENT_ID: 'client_FICTIONAL1' }, 'cfo.example.com')).toEqual({ provider: 'workos', clientId: 'client_FICTIONAL1', devMode: false, error: null })
  })
  it.each(['clerk', 'transition', 'invalid'])('rejects the removed or unknown provider setting %s even with a valid client', provider => {
    expect(authConfiguration({ VITE_AUTH_PROVIDER: provider, VITE_WORKOS_CLIENT_ID: 'client_FICTIONAL1', DEV: true }, 'localhost').error).toBeTruthy()
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
  it('permits no-auth preview only on loopback development with no sign-in configured', () => {
    expect(authConfiguration({ DEV: true }, 'localhost').provider).toBe('preview')
    expect(authConfiguration({ DEV: true }, '0.0.0.0').error).toBeTruthy()
    expect(authConfiguration({ VITE_AUTH_PROVIDER: 'invalid', DEV: true }, 'localhost').error).toBeTruthy()
  })
})
