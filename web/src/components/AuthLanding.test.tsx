// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import type { BrandConfig } from '../api'
import { BrandContext, NEUTRAL_BRAND, type BrandContextValue } from '../contexts/brandContextValue'

import { AuthLanding } from './AuthLanding'

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
    expect(screen.getAllByRole('button', { name: 'Sign in' })).toHaveLength(2)
    expect(screen.getByRole('link', { name: 'Support' }).getAttribute('href')).toBe('https://example.test/support')
    expect(screen.getByRole('link', { name: 'Privacy' })).toBeTruthy()
    expect(screen.getByRole('link', { name: 'Terms' })).toBeTruthy()
    // The coach's own name leads, and the page uses plain words for how to get in.
    expect(screen.getByText('Mel Coaching')).toBeTruthy()
    expect(screen.getByText('Use the email your invitation was sent to.')).toBeTruthy()
    expect(screen.queryByText(/secure seat/i)).toBeNull()
    // The stored platform attribution is never shown to participants.
    expect(screen.queryByText(/VERA/)).toBeNull()
    expect(view.container.querySelector<HTMLImageElement>('.shell-brand-logo')?.src).toBe('https://assets.example.test/island.svg')
  })
})

it('links the public privacy notice when the program has not supplied its own policy URL', () => {
  render(<BrandContext.Provider value={{ ...context, brand: NEUTRAL_BRAND }}><AuthLanding /></BrandContext.Provider>)
  expect(screen.getByRole('link', { name: 'Privacy' }).getAttribute('href')).toBe('/privacy.html')
})

it('uses the brand fallback heading and the same greeting as chat without showing decorative money to assistive technology', () => {
  const view = render(<BrandContext.Provider value={{ ...context, assistantName: 'Mia', brand: { ...brand, welcome_heading: '' } }}><AuthLanding /></BrandContext.Provider>)
  expect(screen.getByRole('heading', { level: 1, name: 'Welcome to Island Money Lab.' })).toBeTruthy()
  expect(screen.getByText('Håfa adai, I’m Mia.')).toBeTruthy()
  expect(screen.getByText('No judgment, no jargon. Tell me what’s going on with your money.')).toBeTruthy()
  const drawing = view.container.querySelector('.auth-landing-phone')!
  expect(drawing.getAttribute('aria-hidden')).toBe('true')
  expect(drawing.querySelectorAll('button, a, input')).toHaveLength(0)
  expect(screen.queryByText(/Lanya chelu|Run your home like|I have an invitation/)).toBeNull()
})
it('retains a full 120-character brand headline and the plain greeting for another assistant', () => {
  const heading = 'A'.repeat(120)
  render(<BrandContext.Provider value={{ ...context, brand: { ...brand, welcome_heading: heading } }}><AuthLanding /></BrandContext.Provider>)
  expect(screen.getByRole('heading', { level: 1, name: heading })).toBeTruthy()
  expect(screen.getByText('Hi, I’m Auntie Mel.')).toBeTruthy()
  expect(screen.getByText(/I’ll prepare anything that changes your numbers for you to review first/)).toBeTruthy()
})

it('leaves the assistant greeting out when a signed-out visitor only has the placeholder assistant name', () => {
  const view = render(<BrandContext.Provider value={{ ...context, assistantName: 'your assistant' }}><AuthLanding /></BrandContext.Provider>)
  expect(view.container.querySelector('.auth-landing-greeting')).toBeNull()
  expect(screen.queryByText(/I’m your assistant/)).toBeNull()
  expect(view.container.querySelector('.auth-landing-phone')).toBeTruthy()
})
