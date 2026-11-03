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

type Rgb = [number, number, number]

/** The first colour on the way from `start` to `target` that reads on every surface, or null. */
function nudgeToward(start: Rgb, target: Rgb, surfaces: Rgb[], minimum: number) {
  for (let step = 1; step <= 20; step += 1) {
    const amount = step / 20
    const color = start.map((channel, index) => channel + (target[index] - channel) * amount) as Rgb
    if (surfaces.every((surface) => contrast(color, surface) >= minimum)) return color
  }
  return null
}

/**
 * Returns `foreground` moved in small steps until it has `minimum`:1 on every background.
 * It moves toward `toward` first (black by default, the usual fix for muted text on
 * light surfaces). If that cannot reach the minimum, for example light text on a dark
 * or mid-tone surface, it tries the opposite extreme before giving up.
 */
export function readableOn(foreground: string, backgrounds: string[], minimum = 4.5, toward = '#000000') {
  const start = parse(foreground)
  const target = parse(toward)
  const surfaces = backgrounds.map(parse).filter((surface): surface is Rgb => surface !== null)
  if (!start || !target || surfaces.length === 0) return foreground
  if (surfaces.every((surface) => contrast(start, surface) >= minimum)) return foreground
  const opposite = target.map((channel) => 255 - channel) as Rgb
  const color = nudgeToward(start, target, surfaces, minimum) ?? nudgeToward(start, opposite, surfaces, minimum)
  return color ? toHex(color) : foreground
}
