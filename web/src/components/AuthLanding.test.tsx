// @vitest-environment jsdom

import type { ReactNode } from 'react'
import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { BrandConfig } from '../api'
import { BrandContext, NEUTRAL_BRAND, type BrandContextValue } from '../contexts/brandContextValue'

vi.mock('@clerk/clerk-react', () => ({
  SignInButton: ({ children }: { children: ReactNode }) => children,
  SignUpButton: ({ children }: { children: ReactNode }) => children,
  UserButton: () => null,
}))

import { AuthLanding } from '../App'

const brand: BrandConfig = {
  schema_version: 1,
  product_name: 'Island Money Lab',
  short_name: 'Island Lab',
  organization_name: 'Mel Coaching',
  participant_role_term: 'member',
  powered_by_name: 'VERA',
  powered_by_placement: 'footer',
  tagline: 'Rooted in community',
  welcome_heading: 'Håfa adai, welcome in.',
  welcome_description: 'A money space built for our island community.',
  logo_url: 'https://assets.example.test/island.svg',
  favicon_url: null,
  support: { label: null, email: null, url: 'https://example.test/support' },
  colors: {
    background: '#f5efe2', surface: '#fffdf8', surface_muted: '#f9f2e7', text: '#17221e', text_muted: '#5f6964', border: '#d9d2c5',
    primary: '#125f52', primary_hover: '#0d493f', primary_soft: '#dceee8', accent: '#bb744b', on_primary: '#ffffff', focus: '#125f52',
  },
  typography: { display: 'lora', body: 'nunito_sans' },
  footer: { text: 'Built for the Island Money Community.', privacy_url: 'https://example.test/privacy', terms_url: 'https://example.test/terms' },
}

const context: BrandContextValue = {
  brand,
  assistantName: 'Auntie Mel',
  hostname: 'money.example.test',
  source: 'published_workspace_brand',
  status: 'ready',
  error: null,
  retry: () => undefined,
  isRuntimeBrand: false,
}

afterEach(() => cleanup())

describe('AuthLanding', () => {
  it('shows the complete coach-owned front door before sign-in', () => {
    const view = render(<BrandContext.Provider value={context}><AuthLanding /></BrandContext.Provider>)

    expect(screen.getByRole('heading', { name: 'Håfa adai, welcome in.' })).toBeTruthy()
    expect(screen.getByText('A money space built for our island community.')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Sign in' })).toBeTruthy()
    expect(screen.getByRole('link', { name: 'Support' }).getAttribute('href')).toBe('https://example.test/support')
    expect(screen.getByRole('link', { name: 'Privacy' })).toBeTruthy()
    expect(screen.getByRole('link', { name: 'Terms' })).toBeTruthy()
    expect(screen.getByText('Powered by VERA')).toBeTruthy()
    expect(view.container.querySelector<HTMLImageElement>('.shell-brand-logo')?.src).toBe('https://assets.example.test/island.svg')
  })
})

it('links the public privacy notice when the program has not supplied its own policy URL', () => {
  render(<BrandContext.Provider value={{ ...context, brand: NEUTRAL_BRAND }}><AuthLanding /></BrandContext.Provider>)
  expect(screen.getByRole('link', { name: 'Privacy' }).getAttribute('href')).toBe('/privacy.html')
})
