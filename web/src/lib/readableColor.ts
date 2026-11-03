// Muted text on the soft rose surface can fall just under 4.5:1 even when the
// brand passes its own authoring checks, so brand colours are nudged toward the
// text colour until they read clearly on every surface they sit on.
function parse(hex: string): [number, number, number] | null {
  const match = /^#([0-9a-f]{6})$/i.exec(hex.trim())
  if (!match) return null
  const value = parseInt(match[1], 16)
  return [(value >> 16) & 255, (value >> 8) & 255, value & 255]
}

function luminance([r, g, b]: [number, number, number]) {
  const channel = (value: number) => {
    const unit = value / 255
    return unit <= 0.03928 ? unit / 12.92 : ((unit + 0.055) / 1.055) ** 2.4
  }
  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
}

function contrast(a: [number, number, number], b: [number, number, number]) {
  const [light, dark] = [luminance(a), luminance(b)].sort((x, y) => y - x)
  return (light + 0.05) / (dark + 0.05)
}

function toHex([r, g, b]: [number, number, number]) {
  return `#${[r, g, b].map((value) => Math.round(value).toString(16).padStart(2, '0')).join('')}`
}

/** Returns `foreground` darkened in small steps until it has `minimum`:1 on every background. */
export function readableOn(foreground: string, backgrounds: string[], minimum = 4.5, toward = '#000000') {
  const start = parse(foreground)
  const target = parse(toward)
  const surfaces = backgrounds.map(parse).filter((surface): surface is [number, number, number] => surface !== null)
  if (!start || !target || surfaces.length === 0) return foreground
  const reads = (color: [number, number, number]) => surfaces.every((surface) => contrast(color, surface) >= minimum)
  for (let step = 0; step <= 20; step += 1) {
    const amount = step / 20
    const color = start.map((channel, index) => channel + (target[index] - channel) * amount) as [number, number, number]
    if (reads(color)) return step === 0 ? foreground : toHex(color)
  }
  return foreground
}
