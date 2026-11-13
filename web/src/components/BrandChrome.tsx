import { useState } from 'react'
import type { BrandConfig } from '../api'
import { useBrand } from '../contexts/brandContextValue'

export function BrandWordmark({ brand }: { brand: BrandConfig }) {
  return brand.organization_name === 'Household CFO Method'
    ? <span className="brand-wordmark">The <em>Household CFO</em></span>
    : <span className="brand-wordmark">{brand.short_name}</span>
}

export function BrandLogo({ brand }: { brand: BrandConfig }) {
  const [failedUrl, setFailedUrl] = useState<string | null>(null)
  const showLogo = Boolean(brand.logo_url && failedUrl !== brand.logo_url)

  return showLogo ? (
    <img
      className="shell-brand-logo"
      src={brand.logo_url ?? undefined}
      alt=""
      referrerPolicy="no-referrer"
      onError={() => setFailedUrl(brand.logo_url)}
    />
  ) : null
}

// Mrs. Mel's closing line belongs to her own method. A coach workspace that sets its own organization
// name never inherits it, and the savings program (which shows its own name) opts out with `closingLine={false}`.
const METHOD_ORGANIZATION = 'Household CFO Method'
const CLOSING_LINE = 'Not just to look wealthy on paper. The goal is to feel safe in your actual life.'

export function BrandFooter({ privacyFallback = false, closingLine = false }: { privacyFallback?: boolean; closingLine?: boolean } = {}) {
  const { brand } = useBrand()
  const supportHref = brand.support.url ?? (brand.support.email ? `mailto:${brand.support.email}` : null)
  const supportLabel = brand.support.label ?? (brand.support.email ? 'Contact support' : 'Support')
  const privacyUrl = brand.footer.privacy_url ?? (privacyFallback ? '/privacy.html' : null)
  const hasLinks = Boolean(supportHref || privacyUrl || brand.footer.terms_url)
  const showClosingLine = closingLine && brand.organization_name === METHOD_ORGANIZATION
  // Platform attribution is never shown to participants (see brandByline).
  if (!brand.footer.text && !hasLinks && !showClosingLine) return null

  return (
    <footer className="brand-footer">
      <div>
        {showClosingLine && <p className="brand-closing-line">{CLOSING_LINE}<span>The {METHOD_ORGANIZATION}</span></p>}
        {brand.footer.text && <p>{brand.footer.text}</p>}
      </div>
      {hasLinks && <nav aria-label="Program support and policies">
        {supportHref && <a href={supportHref} target={brand.support.url ? '_blank' : undefined} rel={brand.support.url ? 'noreferrer' : undefined}>{supportLabel}</a>}
        {privacyUrl && <a href={privacyUrl} target="_blank" rel="noreferrer">Privacy</a>}
        {brand.footer.terms_url && <a href={brand.footer.terms_url} target="_blank" rel="noreferrer">Terms</a>}
      </nav>}
    </footer>
  )
}
