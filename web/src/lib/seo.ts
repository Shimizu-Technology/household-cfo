import type { BrandConfig } from '../api'

export const SITE_NAME = 'VERA'
export const DEFAULT_TITLE = 'VERA | Secure coaching workspace'
export const DEFAULT_DESCRIPTION = 'A secure coaching workspace for reviewing information, planning next steps, and working with your program assistant.'
export const DEFAULT_KEYWORDS = 'VERA, coaching workspace, planning assistant'
export const THEME_COLOR = '#536a63'

type SeoRoute = { title: string; description: string; robots?: string }

export function getSiteUrl() {
  if (typeof window !== 'undefined') return window.location.origin

  const envUrl = import.meta.env.VITE_SITE_URL as string | undefined
  if (envUrl) return envUrl.replace(/\/$/, '')
  return 'https://household-cfo.netlify.app'
}

export function getSectionSeo(section: string, brand?: BrandConfig, assistantName = 'your assistant'): SeoRoute {
  const siteName = brand?.product_name || SITE_NAME
  const tagline = brand?.tagline?.trim()
  const homeDescription = brand?.welcome_description?.trim() || tagline || DEFAULT_DESCRIPTION
  const title = (label: string) => `${label} | ${siteName}`
  const sectionSeo: Record<string, SeoRoute> = {
    Home: { title: tagline ? `${siteName} | ${tagline}` : siteName, description: homeDescription },
    'Ask Mia': { title: title(`Ask ${assistantName}`), description: `Ask ${assistantName} private household finance questions using approved profile, plan, debt, runway, and bank activity context.`, robots: 'noindex,nofollow' },
    Review: { title: title('Review Transactions'), description: 'Review activity and control which records become official household budget actuals.', robots: 'noindex,nofollow' },
    'My Profile': { title: title('My Profile'), description: `Review and update the private household information ${assistantName} may use.`, robots: 'noindex,nofollow' },
    Budget: { title: title('Budget'), description: 'Review household income, expenses, breathing room, and spending pressure.', robots: 'noindex,nofollow' },
    Wealth: { title: title('Wealth'), description: 'Review household assets, debts, net worth, and financial runway.', robots: 'noindex,nofollow' },
    'CFO Filter': { title: title('CFO Filter'), description: `Use ${assistantName} to sort urgent household money decisions from noise.`, robots: 'noindex,nofollow' },
    Optionality: { title: title('Optionality'), description: `Model optionality and runway for the next household decision with ${assistantName}.`, robots: 'noindex,nofollow' },
    Admin: { title: title('Admin'), description: `Secure cohort, user, and invitation management for ${siteName} staff.`, robots: 'noindex,nofollow' },
  }
  return sectionSeo[section] || sectionSeo.Home
}

export function canonicalUrl() {
  return `${getSiteUrl()}/`
}

export function socialImageUrl() {
  return `${getSiteUrl()}/og-image.png`
}

export function webApplicationStructuredData(brand?: BrandConfig) {
  const name = brand?.product_name || SITE_NAME
  const description = brand?.welcome_description?.trim() || brand?.tagline?.trim() || DEFAULT_DESCRIPTION
  return {
    '@context': 'https://schema.org',
    '@type': 'WebApplication',
    name,
    url: canonicalUrl(),
    applicationCategory: 'FinanceApplication',
    operatingSystem: 'Web',
    description,
  }
}
