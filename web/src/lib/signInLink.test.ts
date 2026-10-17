import { describe, expect, it } from 'vitest'
import { shareableSignInUrl } from './signInLink'

describe('shareableSignInUrl', () => {
  it('uses the page origin when the API reports a different loopback address', () => {
    expect(shareableSignInUrl('http://localhost:5173', 'http://127.0.0.1:5215')).toBe('http://127.0.0.1:5215')
  })
  it('keeps a real program domain', () => {
    expect(shareableSignInUrl('https://mel.example.org', 'http://127.0.0.1:5215')).toBe('https://mel.example.org')
  })
  it('keeps the API url when the page is not local', () => {
    expect(shareableSignInUrl('http://localhost:5173', 'https://app.example.org')).toBe('http://localhost:5173')
  })
  it('returns null without a link', () => {
    expect(shareableSignInUrl(null, 'http://127.0.0.1:5215')).toBeNull()
  })
})
