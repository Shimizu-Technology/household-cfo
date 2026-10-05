import { useLayoutEffect } from 'react'
import { useBrand } from '../contexts/brandContextValue'

const displayFonts: Record<string, string> = {
  cormorant_garamond: '"Cormorant Garamond", Georgia, serif',
  lora: 'Lora, Georgia, serif',
  merriweather: 'Merriweather, Georgia, serif',
  playfair_display: '"Playfair Display", Georgia, serif',
  source_serif_4: '"Source Serif 4", Georgia, serif',
  system_serif: 'Georgia, "Times New Roman", serif',
}

const bodyFonts: Record<string, string> = {
  inter: 'Inter, ui-sans-serif, system-ui, sans-serif',
  montserrat: 'Montserrat, ui-sans-serif, system-ui, sans-serif',
  nunito_sans: '"Nunito Sans", ui-sans-serif, system-ui, sans-serif',
  source_sans_3: '"Source Sans 3", ui-sans-serif, system-ui, sans-serif',
  system_sans: 'ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
}

export function BrandDocument() {
  const { brand } = useBrand()

  useLayoutEffect(() => {
    const root = document.documentElement
    const displayFont = displayFonts[brand.typography.display] ?? displayFonts.system_serif
    const bodyFont = bodyFonts[brand.typography.body] ?? bodyFonts.system_sans
    const variables: Record<string, string> = {
      '--surface-page': brand.colors.background,
      '--surface': brand.colors.surface,
      '--surface-muted': brand.colors.surface_muted,
      '--text-primary': brand.colors.text,
      '--text-muted': brand.colors.text_muted,
      '--border-subtle': brand.colors.border,
      '--action-primary': brand.colors.primary,
      '--action-primary-hover': brand.colors.primary_hover,
      '--action-primary-soft': brand.colors.primary_soft,
      '--action-on-primary': brand.colors.on_primary,
      '--focus-color': brand.colors.focus,
      '--cream': brand.colors.background,
      '--paper': brand.colors.surface,
      '--paper-warm': brand.colors.surface_muted,
      '--paper-deep': brand.colors.surface_muted,
      '--ink': brand.colors.text,
      '--ink-soft': brand.colors.text_muted,
      '--muted': brand.colors.text_muted,
      '--line': brand.colors.border,
      '--emerald': brand.colors.primary,
      '--mauve': brand.colors.primary,
      '--berry': brand.colors.primary_hover,
      '--emerald-soft': brand.colors.primary_soft,
      '--gold': brand.colors.accent,
      '--plum': brand.colors.text,
      '--brand-on-primary': brand.colors.on_primary,
      '--brand-primary-hover': brand.colors.primary_hover,
      '--brand-focus': brand.colors.focus,
      '--font-display': displayFont,
      '--serif-font': displayFont,
      '--number-font': bodyFont,
      '--font-body': bodyFont,
    }
    const priorVariables = new Map(Object.keys(variables).map((name) => [name, root.style.getPropertyValue(name)]))
    const priorFontFamily = root.style.fontFamily
    const priorTitle = document.title
    const theme = document.head.querySelector<HTMLMetaElement>('meta[name="theme-color"]')
    const priorTheme = theme?.getAttribute('content') ?? null
    const favicon = document.head.querySelector<HTMLLinkElement>('link[rel="icon"]')
    const priorFaviconHref = favicon?.getAttribute('href') ?? null
    const priorBrandHref = favicon?.dataset.brandHref
    const priorFaviconError = favicon?.onerror ?? null

    Object.entries(variables).forEach(([name, value]) => root.style.setProperty(name, value))
    root.style.fontFamily = bodyFont
    document.title = brand.tagline ? `${brand.product_name} | ${brand.tagline}` : brand.product_name

    theme?.setAttribute('content', brand.colors.primary)

    if (favicon) {
      const requestedHref = brand.favicon_url ?? '/favicon.svg'
      favicon.dataset.brandHref = requestedHref
      favicon.onerror = () => {
        if (favicon.dataset.brandHref !== requestedHref) return
        favicon.onerror = null
        favicon.href = '/favicon.svg'
      }
      favicon.href = requestedHref
    }

    return () => {
      priorVariables.forEach((value, name) => {
        if (value) root.style.setProperty(name, value)
        else root.style.removeProperty(name)
      })
      root.style.fontFamily = priorFontFamily
      document.title = priorTitle
      if (theme) {
        if (priorTheme === null) theme.removeAttribute('content')
        else theme.setAttribute('content', priorTheme)
      }
      if (favicon) {
        favicon.onerror = priorFaviconError
        if (priorFaviconHref === null) favicon.removeAttribute('href')
        else favicon.setAttribute('href', priorFaviconHref)
        if (priorBrandHref === undefined) delete favicon.dataset.brandHref
        else favicon.dataset.brandHref = priorBrandHref
      }
    }
  }, [brand])

  return null
}
