import { describe, expect, it } from 'vitest'
import { authConfiguration } from './authConfig'
const valid = { VITE_AUTH_PROVIDER: 'workos', VITE_WORKOS_CLIENT_ID: 'client_ABC123', VITE_WORKOS_API_HOSTNAME: 'auth.example.com' }
describe('auth provider configuration', () => {
  it('keeps Clerk as the transition default and closes production without configuration', () => {
    expect(authConfiguration({ PROD: true }, 'cfo.example.com')).toMatchObject({ provider: 'clerk', devMode: false, error: expect.any(String) })
    expect(authConfiguration({ PROD: true, VITE_CLERK_PUBLISHABLE_KEY: 'pk_live_valid' }, 'cfo.example.com')).toMatchObject({ provider: 'clerk', error: null })
  })
  it('never enables WorkOS localStorage refresh tokens in a production build, even on localhost', () => {
    expect(authConfiguration({ ...valid, PROD: true, DEV: false }, 'localhost')).toMatchObject({ provider: 'workos', error: null, devMode: false })
    expect(authConfiguration({ ...valid, DEV: true }, 'localhost').devMode).toBe(true)
    expect(authConfiguration({ ...valid, DEV: true }, 'staging.example.com').devMode).toBe(false)
  })
  it.each([{ VITE_WORKOS_CLIENT_ID: '' }, { VITE_WORKOS_API_HOSTNAME: '' }, { VITE_WORKOS_API_HOSTNAME: 'api.workos.com' }, { VITE_WORKOS_API_HOSTNAME: 'https://auth.example.com/path' }, { VITE_AUTH_PROVIDER: 'bogus' }])('fails closed for invalid production configuration %j', override => {
    expect(authConfiguration({ ...valid, PROD: true, ...override }, 'cfo.example.com').error).toBeTruthy()
  })
  it('permits preview only on loopback development with Clerk unconfigured', () => {
    expect(authConfiguration({ DEV: true }, 'localhost').provider).toBe('preview')
    expect(authConfiguration({ DEV: true }, '0.0.0.0').error).toBeTruthy()
    expect(authConfiguration({ ...valid, DEV: true, VITE_WORKOS_CLIENT_ID: '' }, 'localhost').error).toBeTruthy()
  })
})
