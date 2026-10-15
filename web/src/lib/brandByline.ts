import type { BrandConfig } from '../api'

export function brandByline(brand: BrandConfig) {
  if (brand.powered_by_placement === 'header' && brand.powered_by_name) {
    return `${brand.organization_name} powered by ${brand.powered_by_name}`
  }
  return brand.organization_name
}
