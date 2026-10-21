import type { BrandConfig } from '../api'

// Participants only ever see the coach's own brand. The platform attribution
// (`powered_by_name`) stays in the stored config for evidence, but is never
// rendered: "Consumers never see the name VERA."
export function brandByline(brand: BrandConfig) {
  return brand.organization_name
}

// The shell header already shows the short name, so only repeat the
// organization when it adds something (e.g. "ASC Trust" over "Household CFO").
export function brandHeaderByline(brand: BrandConfig) {
  const organization = brand.organization_name.trim()
  const short = brand.short_name.trim()
  if (!organization || organization.toLocaleLowerCase().startsWith(short.toLocaleLowerCase())) return null
  return organization
}
