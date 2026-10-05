// @vitest-environment jsdom

import { cleanup, render } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import type { BrandConfig } from '../api'
import { BrandDocument } from './BrandDocument'
import { BrandContext, type BrandContextValue } from '../contexts/brandContextValue'

const brand: BrandConfig = {
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
  favicon_url: 'https://assets.example.test/island.ico',
  support: { label: 'Ask Mel', email: 'mel@example.com', url: null },
  colors: {
    background: '#f5efe2', surface: '#fffdf8', surface_muted: '#f9f2e7', text: '#17221e', text_muted: '#5f6964', border: '#d9d2c5',
    primary: '#125f52', primary_hover: '#0d493f', primary_soft: '#dceee8', accent: '#bb744b', on_primary: '#ffffff', focus: '#125f52',
  },
  typography: { display: 'lora', body: 'nunito_sans' },
  footer: { text: 'Island Money Lab', privacy_url: null, terms_url: null },
}

function value(config = brand): BrandContextValue {
  return { brand: config, assistantName: 'Auntie Mel', hostname: 'coach.example.test', source: 'cohort_release', status: 'ready', error: null, retry: () => undefined, isRuntimeBrand: true }
}

afterEach(() => cleanup())

describe('BrandDocument', () => {
  it('applies a runtime brand and restores the previous public document identity on unmount', () => {
    document.title = 'VERA'
    document.documentElement.style.setProperty('--emerald', '#536a63')
    const favicon = document.head.querySelector<HTMLLinkElement>('link[rel="icon"]') ?? document.head.appendChild(document.createElement('link'))
    favicon.rel = 'icon'
    favicon.href = '/favicon.svg'

    const view = render(<BrandContext.Provider value={value()}><BrandDocument /></BrandContext.Provider>)

    expect(document.title).toBe('Island Money Lab | Rooted in community')
    expect(document.documentElement.style.getPropertyValue('--emerald')).toBe('#125f52')
    for (const [token, expected] of Object.entries({
      '--surface-page': brand.colors.background, '--surface': brand.colors.surface,
      '--surface-muted': brand.colors.surface_muted, '--text-primary': brand.colors.text,
      '--text-muted': brand.colors.text_muted, '--border-subtle': brand.colors.border,
      '--action-primary': brand.colors.primary, '--action-primary-hover': brand.colors.primary_hover,
      '--action-primary-soft': brand.colors.primary_soft, '--action-on-primary': brand.colors.on_primary,
      '--focus-color': brand.colors.focus,
    })) expect(document.documentElement.style.getPropertyValue(token)).toBe(expected)

    expect(favicon.getAttribute('href')).toBe('https://assets.example.test/island.ico')

    view.unmount()
    expect(document.title).toBe('VERA')
    expect(document.documentElement.style.getPropertyValue('--emerald')).toBe('#536a63')
    expect(document.documentElement.style.getPropertyValue('--action-primary')).toBe('')
    expect(document.documentElement.style.getPropertyValue('--surface')).toBe('')
    expect(favicon.getAttribute('href')).toBe('/favicon.svg')
  })

  it('updates semantic controls when a different runtime palette replaces the current brand', () => {
    const view = render(<BrandContext.Provider value={value()}><BrandDocument /></BrandContext.Provider>)
    const rose = { ...brand, colors: { ...brand.colors, primary: '#7b4a58', surface: '#f8eee5', on_primary: '#fffdf8', focus: '#613344' } }
    view.rerender(<BrandContext.Provider value={value(rose)}><BrandDocument /></BrandContext.Provider>)
    expect(document.documentElement.style.getPropertyValue('--action-primary')).toBe('#7b4a58')
    expect(document.documentElement.style.getPropertyValue('--surface')).toBe('#f8eee5')
    expect(document.documentElement.style.getPropertyValue('--action-on-primary')).toBe('#fffdf8')
    expect(document.documentElement.style.getPropertyValue('--focus-color')).toBe('#613344')
  })

  it('falls back to the neutral favicon when a branded asset fails', () => {
    const favicon = document.head.querySelector<HTMLLinkElement>('link[rel="icon"]') ?? document.head.appendChild(document.createElement('link'))
    favicon.rel = 'icon'
    const view = render(<BrandContext.Provider value={value()}><BrandDocument /></BrandContext.Provider>)

    favicon.dispatchEvent(new Event('error'))
    expect(favicon.getAttribute('href')).toBe('/favicon.svg')

    view.unmount()
  })
})
