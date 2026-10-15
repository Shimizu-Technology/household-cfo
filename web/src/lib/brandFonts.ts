// Only the active brand's two families are requested, instead of every font a brand could choose.
const googleFontFamilies: Record<string, string> = {
  cormorant_garamond: 'Cormorant+Garamond:wght@500;600;700',
  lora: 'Lora:wght@500;600;700',
  merriweather: 'Merriweather:wght@400;700',
  playfair_display: 'Playfair+Display:wght@500;600;700',
  source_serif_4: 'Source+Serif+4:wght@500;600;700',
  inter: 'Inter:wght@400;500;600;700',
  montserrat: 'Montserrat:wght@400;500;600;700',
  nunito_sans: 'Nunito+Sans:wght@400;500;600;700',
  source_sans_3: 'Source+Sans+3:wght@400;500;600;700',
}

// Served from /fonts and preloaded by index.html; requesting them again would only add a font swap.
const selfHostedFamilies = new Set(['cormorant_garamond', 'montserrat'])

export function brandFontStylesheetHref(display: string, body: string): string | null {
  const families = [display, body]
    .filter((key) => !selfHostedFamilies.has(key))
    .map((key) => googleFontFamilies[key])
    .filter((family): family is string => Boolean(family))
  if (families.length === 0) return null
  return `https://fonts.googleapis.com/css2?${families.map((family) => `family=${family}`).join('&')}&display=swap`
}
