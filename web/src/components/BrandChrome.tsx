import { useState } from 'react'
import type { BrandConfig } from '../api'
import { useBrand } from '../contexts/brandContextValue'

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

export function BrandFooter({ privacyFallback = false }: { privacyFallback?: boolean } = {}) {
  const { brand } = useBrand()
  const supportHref = brand.support.url ?? (brand.support.email ? `mailto:${brand.support.email}` : null)
  const supportLabel = brand.support.label ?? (brand.support.email ? 'Contact support' : 'Support')
  const privacyUrl = brand.footer.privacy_url ?? (privacyFallback ? '/privacy.html' : null)
  const hasLinks = Boolean(supportHref || privacyUrl || brand.footer.terms_url)
  const poweredBy = brand.powered_by_placement === 'footer' ? brand.powered_by_name : null
  if (!brand.footer.text && !hasLinks && !poweredBy) return null

  return (
    <footer className="brand-footer">
      <div>
        {brand.footer.text && <p>{brand.footer.text}</p>}
        {poweredBy && <small>Powered by {poweredBy}</small>}
      </div>
      {hasLinks && <nav aria-label="Program support and policies">
        {supportHref && <a href={supportHref} target={brand.support.url ? '_blank' : undefined} rel={brand.support.url ? 'noreferrer' : undefined}>{supportLabel}</a>}
        {privacyUrl && <a href={privacyUrl} target="_blank" rel="noreferrer">Privacy</a>}
        {brand.footer.terms_url && <a href={brand.footer.terms_url} target="_blank" rel="noreferrer">Terms</a>}
      </nav>}
    </footer>
  )
}
