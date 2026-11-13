import { readableOn } from './readableColor'

/** Mix two validated brand hex colours, in sRGB as CSS color-mix does. */
function mix(a: string, b: string, share: number) {
  const channel = (hex: string, index: number) => parseInt(hex.slice(index, index + 2), 16)
  return '#' + [1, 3, 5].map(index => Math.round(channel(a, index) * share + channel(b, index) * (1 - share)).toString(16).padStart(2, '0')).join('')
}

/** One derived answer surface per brand; never an independently authored palette. */
export function brandDeep(primary: string, ground: string) {
  // A dark page ground cannot reach 7:1 against black. Move only that
  // foreground toward white first, so the answer shade never gets lightened
  // by readableOn's opposite-extreme fallback.
  const on = readableOn(ground, ['#000000'], 7, '#ffffff')
  const deep = readableOn(mix(primary, '#000000', 0.6), [on], 7)
  const muted = readableOn(mix(on, deep, 0.8), [deep], 4.5, on)
  return { '--brand-deep': deep, '--on-brand-deep': on, '--on-brand-deep-muted': muted }
}
