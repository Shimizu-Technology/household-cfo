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
    expect(favicon.getAttribute('href')).toBe('https://assets.example.test/island.ico')

    view.unmount()
    expect(document.title).toBe('VERA')
    expect(document.documentElement.style.getPropertyValue('--emerald')).toBe('#536a63')
    expect(favicon.getAttribute('href')).toBe('/favicon.svg')
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
