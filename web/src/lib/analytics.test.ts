import { afterEach, describe, expect, it, vi } from 'vitest'
import { maskCapturedNetworkRequest, redactAnalyticsEvent, redactAnalyticsUrl } from './analytics'

afterEach(() => vi.unstubAllEnvs())

describe('authentication URL privacy', () => {
  it('excludes browser session responses from replay even if remote capture includes their token body', () => {
    expect(maskCapturedNetworkRequest({ name: '/api/auth/session', duration: 30, entryType: 'resource', startTime: 0, responseBody: '{"access_token":"fictional-token"}' })).toBeNull()
  })
  it('keeps request timing without exposing credentials, financial payloads or uploaded contents', () => {
    expect(maskCapturedNetworkRequest({ name: 'https://api.example/api/v1/profile', duration: 30, entryType: 'resource', startTime: 0,
      requestHeaders: { Authorization: 'Bearer fictional-token' }, responseHeaders: { 'Set-Cookie': 'fictional-session' }, requestBody: 'private statement contents', responseBody: '{"income":4500}' })).toEqual({ name: 'https://api.example/api/v1/profile', duration: 30, entryType: 'resource', startTime: 0 })
  })
  it('scrubs SDK-generated event and person URL metadata before transmission', () => {
    const secretUrl = 'https://app.example/login?invitation_token=fictional-secret'
    const event = { uuid: 'test', event: '$identify', properties: { $current_url: secretUrl, $set_once: { $initial_current_url: secretUrl }, section: 'income' }, $set: { $referrer: secretUrl } }
    expect(redactAnalyticsEvent(event)).toEqual({ uuid: 'test', event: '$identify', properties: { $current_url: 'https://app.example/login?invitation_token=[REDACTED]', $set_once: { $initial_current_url: 'https://app.example/login?invitation_token=[REDACTED]' }, section: 'income' }, $set: { $referrer: 'https://app.example/login?invitation_token=[REDACTED]' } })
    expect(redactAnalyticsEvent(null)).toBeNull()
  })
  it('removes OAuth, invitation and session credentials while preserving useful route context', () => {
    const input = 'https://app.example/auth/callback?code=one&state=two&invitation_token=three&access_token=four&refresh_token=five&authorization_session_id=six&section=income'
    const result = redactAnalyticsUrl(input)
    expect(result).toBe('https://app.example/auth/callback?code=[REDACTED]&state=[REDACTED]&invitation_token=[REDACTED]&access_token=[REDACTED]&refresh_token=[REDACTED]&authorization_session_id=[REDACTED]&section=income')
  })

  it('removes secret Admin Portal paths for standard and configured hosts', () => {
    expect(redactAnalyticsUrl('https://setup.workos.com/session/secret?organization=bank')).toBe('https://setup.workos.com/[REDACTED]')
    vi.stubEnv('VITE_WORKOS_ADMIN_PORTAL_HOSTNAME', 'setup.example.com')
    expect(redactAnalyticsUrl('https://setup.example.com/session/secret')).toBe('https://setup.example.com/[REDACTED]')
    expect(redactAnalyticsUrl('https://setup.example.com.evil.test/public')).toBe('https://setup.example.com.evil.test/public')
  })
})
