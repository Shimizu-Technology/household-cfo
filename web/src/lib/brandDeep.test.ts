import { describe, expect, it } from 'vitest'
import { brandDeep } from './brandDeep'
import { readableOn } from './readableColor'

// Independent WCAG calculation, rather than a snapshot of the helper's output.
function contrast(a: string, b: string) {
  const luminance = (hex: string) => [1, 3, 5].map(index => parseInt(hex.slice(index, index + 2), 16) / 255)
    .map(c => c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4)
    .reduce((sum, c, i) => sum + c * [0.2126, 0.7152, 0.0722][i], 0)
  const [light, dark] = [luminance(a), luminance(b)].sort((x, y) => y - x)
  return (light + 0.05) / (dark + 0.05)
}

describe('derived brand answer colours', () => {
  for (const primary of ['#7b4a58', '#1f3a5f', '#ffe066']) {
    it(`keeps ground text at 7:1 and muted text at 4.5:1 for ${primary}`, () => {
      const tokens = brandDeep(primary, '#f7f2ea')
      expect(tokens['--on-brand-deep']).toBe('#f7f2ea')
      expect(contrast(tokens['--on-brand-deep'], tokens['--brand-deep'])).toBeGreaterThanOrEqual(7)
      expect(contrast(tokens['--on-brand-deep-muted'], tokens['--brand-deep'])).toBeGreaterThanOrEqual(4.5)
      expect(readableOn(tokens['--brand-deep'], ['#f7f2ea'], 7)).toBe(tokens['--brand-deep'])
    })
  }
  it('starts with the chosen 60 percent primary shade', () => {
    expect(brandDeep('#7b4a58', '#f7f2ea')['--brand-deep']).toBe('#4a2c35')
  })
  it('remains readable when a brand has a dark page ground', () => {
    const tokens = brandDeep('#1f3a5f', '#101820')
    // Its deep shade must stay dark, even when the page ground is dark too.
    expect(parseInt(tokens['--brand-deep'].slice(1), 16)).toBeLessThanOrEqual(0x132339)
    expect(contrast(tokens['--on-brand-deep'], tokens['--brand-deep'])).toBeGreaterThanOrEqual(7)
    expect(contrast(tokens['--on-brand-deep-muted'], tokens['--brand-deep'])).toBeGreaterThanOrEqual(4.5)
  })
})
