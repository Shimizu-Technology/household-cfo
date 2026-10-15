import { describe, expect, it } from 'vitest'
import { ApiRequestError } from '../api'
import { participantErrorMessage } from './participantErrorMessage'

const api = (message: string, status: number, code?: string) => new ApiRequestError(message, { status, code })

describe('participantErrorMessage', () => {
  it('maps known codes to plain sentences', () => {
    expect(participantErrorMessage(api('Your financial picture changed. Reload before saving or sending again. Nothing changed.', 409, 'financial_generation_stale'), 'fallback'))
      .toBe('Something changed since this page loaded. Refresh and try again. Nothing was saved.')
    expect(participantErrorMessage(api('Too many requests', 429, 'rate_limited'), 'fallback')).toMatch(/going a little fast/)
  })

  it('never shows server faults or raw status text', () => {
    expect(participantErrorMessage(api('API request failed: 500', 500), 'fallback')).toMatch(/^Something went wrong on our side/)
    expect(participantErrorMessage(api('API request failed: 418', 418), 'Could not save.')).toBe('Could not save.')
    expect(participantErrorMessage(api('Private daily record not found', 404), 'fallback')).toBe('We couldn’t find that anymore. Refresh to see the latest.')
    expect(participantErrorMessage(api('Invalid or expired authentication token', 401), 'fallback')).toBe('Your sign-in has ended. Sign in again to continue.')
  })

  it('keeps plain server guidance and replaces technical wording', () => {
    expect(participantErrorMessage(api('Amount must be greater than 0', 422), 'fallback')).toBe('Amount must be greater than 0')
    expect(participantErrorMessage(api('This Household CFO invitation has been revoked.', 403), 'fallback')).toBe('This Household CFO invitation has been revoked.')
    expect(participantErrorMessage(api('Use exact integer cents or versions', 422), 'Could not save this amount.')).toBe('Could not save this amount.')
    expect(participantErrorMessage(api('A valid savings request identity is required.', 422), 'Could not save.')).toBe('Could not save.')
    expect(participantErrorMessage(api('', 403), 'fallback')).toBe('Your account doesn’t have access to this. Contact your program team if that seems wrong.')
  })

  it('explains connection failures and keeps app-written messages', () => {
    expect(participantErrorMessage(new Error('API request could not reach the server. This workspace is temporarily unavailable.'), 'fallback'))
      .toBe('We couldn’t reach the server. Check your connection and try again.')
    expect(participantErrorMessage(new TypeError('Failed to fetch'), 'fallback')).toMatch(/couldn’t reach the server/)
    expect(participantErrorMessage(new Error('Choose a category before confirming.'), 'fallback')).toBe('Choose a category before confirming.')
    expect(participantErrorMessage('not an error', 'fallback')).toBe('fallback')
  })
})
