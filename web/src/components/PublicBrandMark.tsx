import { useBrand } from '../contexts/brandContextValue'
import { BrandLogo, BrandWordmark } from './BrandChrome'

// Small entry-only identity; safe to use before the workspace chunk loads.
export function PublicBrandMark({ pending = false, subtitle }: { pending?: boolean; subtitle?: string }) {
  const { brand } = useBrand()
  const detail = subtitle ?? brand.organization_name
  return <div className="public-state-brand">{pending
    ? <span className="workspace-opening-brand">Secure workspace</span>
    : <><BrandLogo brand={brand} /><BrandWordmark brand={brand} />{detail !== brand.short_name && <span className="workspace-opening-brand">{detail}</span>}</>}
  </div>
}
