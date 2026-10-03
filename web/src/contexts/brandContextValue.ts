import { createContext, useContext } from 'react'
import type { BrandConfig } from '../api'

export const NEUTRAL_BRAND: BrandConfig = {
  schema_version: 1,
  product_name: 'VERA',
  short_name: 'VERA',
  organization_name: 'VERA',
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
    primary: '#536a63', primary_hover: '#3f524c', primary_soft: '#e5ece9', accent: '#9a7457', on_primary: '#ffffff', focus: '#536a63',
  },
  typography: { display: 'system_serif', body: 'system_sans' },
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
