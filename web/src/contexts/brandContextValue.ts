import { createContext, useContext } from 'react'
import type { BrandConfig } from '../api'

export const NEUTRAL_BRAND: BrandConfig = {
  schema_version: 1,
  product_name: 'Household CFO',
  short_name: 'Household CFO',
  organization_name: 'Household CFO',
  participant_role_term: 'participant',
  powered_by_name: null,
  powered_by_placement: 'hidden',
  tagline: 'A secure coaching experience',
  welcome_heading: 'This program link is not available',
  welcome_description: 'Check the address from your coach and try again.',
  logo_url: null,
  favicon_url: null,
  support: { label: null, email: null, url: null },
  colors: {
    background: '#f7f2ea', surface: '#fffdf8', surface_muted: '#fbf7ef', text: '#1f2421', text_muted: '#706d66', border: '#e2d9cb',
    primary: '#7b4a58', primary_hover: '#683d49', primary_soft: '#f1e2e3', accent: '#b97352', on_primary: '#ffffff', focus: '#7b4a58',
  },
  typography: { display: 'cormorant_garamond', body: 'montserrat' },
  footer: { text: null, privacy_url: null, terms_url: null },
}

export type BrandBootstrapStatus = 'loading' | 'ready' | 'unavailable' | 'error'

export type BrandContextValue = {
  brand: BrandConfig
  assistantName: string
  hostname: string
  source: string
  status: BrandBootstrapStatus
  error: string | null
  retry: () => void
  isRuntimeBrand: boolean
}

export const BrandContext = createContext<BrandContextValue>({
  brand: NEUTRAL_BRAND,
  assistantName: 'your assistant',
  hostname: '',
  source: 'safe_default',
  status: 'unavailable',
  error: null,
  retry: () => undefined,
  isRuntimeBrand: false,
})

export function useBrand() {
  return useContext(BrandContext)
}
