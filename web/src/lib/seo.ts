export const SITE_NAME = 'Household CFO Method powered by VERA'
export const DEFAULT_TITLE = `${SITE_NAME} | Run your home like the C-Suite`
export const DEFAULT_DESCRIPTION = "A private first-cohort money coaching workspace for building an annual household budget rhythm, tracking running totals, and getting Mia's AI coaching on the next CFO call."
export const DEFAULT_KEYWORDS = 'household CFO method, VERA, Mia, financial coaching, budget coaching, Guam financial education'
export const THEME_COLOR = '#7b4a58'

const sectionSeo: Record<string, { title: string; description: string; robots?: string }> = {
  Home: {
    title: DEFAULT_TITLE,
    description: DEFAULT_DESCRIPTION,
  },
  'Ask Mia': {
    title: `Ask Mia | ${SITE_NAME}`,
    description: 'Ask Mia private household finance questions using approved profile, budget, debt, runway, and document context.',
    robots: 'noindex,nofollow',
  },
  'My Profile': {
    title: `My Profile | ${SITE_NAME}`,
    description: 'Review and update private household profile, budget, income, debt, assets, and document imports for Mia.',
    robots: 'noindex,nofollow',
  },
  Budget: {
    title: `Budget | ${SITE_NAME}`,
    description: 'Review household expense stack, breathing room, and spending pressure in a private Household CFO workspace.',
    robots: 'noindex,nofollow',
  },
  Wealth: {
    title: `Wealth | ${SITE_NAME}`,
    description: 'Review household assets, debts, net worth, and financial runway in a private Household CFO workspace.',
    robots: 'noindex,nofollow',
  },
  'CFO Filter': {
    title: `CFO Filter | ${SITE_NAME}`,
    description: 'Use Mia’s CFO filter to sort urgent household money decisions from noise.',
    robots: 'noindex,nofollow',
  },
  Optionality: {
    title: `Optionality | ${SITE_NAME}`,
    description: 'Model optionality and runway for the next household decision with Mia.',
    robots: 'noindex,nofollow',
  },
  Admin: {
    title: `Admin | ${SITE_NAME}`,
    description: 'Secure cohort, user, and invitation management for Household CFO staff.',
    robots: 'noindex,nofollow',
  },
}

export function getSiteUrl() {
  const envUrl = import.meta.env.VITE_SITE_URL as string | undefined
  if (envUrl) return envUrl.replace(/\/$/, '')
  if (typeof window !== 'undefined') return window.location.origin
  return 'https://household-cfo.netlify.app'
}

export function getSectionSeo(section: string) {
  return sectionSeo[section] || sectionSeo.Home
}

export function canonicalUrl() {
  return `${getSiteUrl()}/`
}

export function socialImageUrl() {
  return `${getSiteUrl()}/og-image.png`
}

export function webApplicationStructuredData() {
  return {
    '@context': 'https://schema.org',
    '@type': 'WebApplication',
    name: SITE_NAME,
    url: canonicalUrl(),
    applicationCategory: 'FinanceApplication',
    operatingSystem: 'Web',
    description: DEFAULT_DESCRIPTION,
  }
}
