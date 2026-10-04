// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { BrandBootstrapState } from '../components/BrandBootstrapState'
import type { BrandConfig } from '../api'
import { BrandProvider } from './BrandContext'

const recoveredBrand: BrandConfig = {
  schema_version: 1,
  product_name: 'Island Money Lab',
  short_name: 'Island Lab',
  organization_name: 'Mel Coaching',
  participant_role_term: 'member',
  powered_by_name: 'VERA',
  powered_by_placement: 'footer',
  tagline: 'Rooted in community',
  welcome_heading: 'Håfa adai',
  welcome_description: 'Welcome to your coaching space.',
  logo_url: null,
  favicon_url: null,
  support: { label: 'Ask Mel', email: 'mel@example.com', url: null },
  colors: {
    background: '#f5efe2', surface: '#fffdf8', surface_muted: '#f9f2e7', text: '#17221e', text_muted: '#5f6964', border: '#d9d2c5',
    primary: '#125f52', primary_hover: '#0d493f', primary_soft: '#dceee8', accent: '#bb744b', on_primary: '#ffffff', focus: '#125f52',
  },
  typography: { display: 'lora', body: 'nunito_sans' },
  footer: { text: null, privacy_url: null, terms_url: null },
}

afterEach(() => {
  cleanup()
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe('BrandProvider', () => {
  it('shows participant-safe timeout copy and recovers with one explicit retry', async () => {
    vi.useFakeTimers()
    const fetchMock = vi.fn()
      .mockImplementationOnce((_url: string, options: RequestInit) => new Promise((_resolve, reject) => {
        options.signal?.addEventListener('abort', () => reject(options.signal?.reason))
      }))
      .mockResolvedValueOnce({
        status: 200,
        json: async () => ({
          brand: recoveredBrand,
          source: 'published_workspace_brand',
          available: true,
          workspace: { slug: 'island-money' },
          version: { number: 2, digest: 'brand-v2' },
          primary_domain: 'localhost',
        }),
      } as Response)
    vi.stubGlobal('fetch', fetchMock)

    render(<BrandProvider><BrandBootstrapState /></BrandProvider>)
    expect(screen.getByRole('heading', { name: 'Loading your coaching workspace…' })).toBeTruthy()

    await act(async () => { await vi.advanceTimersByTimeAsync(9_001) })
    expect(screen.getByRole('alert').textContent).toBe('This program took too long to load. Check your connection and try again.')
    expect(screen.getByRole('heading', { name: 'Your program could not load' })).toBeTruthy()
    expect(document.body.textContent).not.toContain('Branding request timed out')

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
      await Promise.resolve()
      await Promise.resolve()
    })

    expect(screen.getByRole('heading', { name: 'Håfa adai' })).toBeTruthy()
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })
})
