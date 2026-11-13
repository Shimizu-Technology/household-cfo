/** SVG backgrounds do not inherit currentColor from their HTML control. Pass
 * the resolved brand text colour explicitly, then keep CSS variable-driven. */
export function selectChevron(color: string) {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path d="m4 6 4 4 4-4" fill="none" stroke="${color}" stroke-width="1.5" stroke-linecap="round"/></svg>`
  return `url("data:image/svg+xml,${encodeURIComponent(svg)}")`
}
