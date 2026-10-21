import postcss from 'postcss'

const compact = (value) => value.replace(/\s+/g, ' ').trim()
const fineHover = /\(hover:\s*hover\)\s+and\s+\(pointer:\s*fine\)/i
const absoluteUnitPx = { px: 1, pt: 96 / 72, pc: 16, in: 96, cm: 96 / 2.54, mm: 96 / 25.4, q: 96 / 101.6 }

function thickSideBorder(prop, value) {
  const tokens = postcss.list.space(value)
  const widths = tokens.flatMap((token) => {
    const match = token.match(/^(\d*\.?\d+)([a-z%]*)$/)
    return match ? [{ amount: Number(match[1]), unit: match[2] }] : []
  })
  if (tokens.some((token) => token === 'medium' || token === 'thick')) return true
  // Relative units depend on the element/root/viewport. A literal hairline in
  // absolute units is provable; unresolved positive lengths require review.
  if (widths.some(({ amount, unit }) => amount > 0 && (!(unit in absoluteUnitPx) || amount * absoluteUnitPx[unit] > 1))) return true
  if (tokens.some((token) => /^(?:calc|min|max|clamp|calc-size|anchor-size)\(/.test(token))) return true
  const explicitWidth = widths.length > 0 || tokens.includes('thin')
  if (explicitWidth) return false
  // A custom property may be the width in any shorthand position. With no
  // explicit width, visible border styles default to `medium` (usually 3px).
  return prop.endsWith('-width') || tokens.some((token) => /^(?:var|env)\(/.test(token)
    || /^(?:inherit|solid|dashed|dotted|double|groove|ridge|inset|outset)$/.test(token))
}

// Source-level policy: overridden/dead declarations are checked too. No runtime
// selector guessing or blanket "card" exception can hide new decoration.
export function cssPolicyFindings(source, file) {
  const findings = []
  const root = postcss.parse(source, { from: file })
  const record = (node, kind) => {
    const ancestry = []
    for (let parent = node.parent; parent && parent.type !== 'root'; parent = parent.parent) {
      if (parent.type === 'atrule') ancestry.unshift(`@${parent.name} ${compact(parent.params)}`)
    }
    const rule = node.type === 'rule' ? node : node.parent
    const selector = rule.type === 'rule' ? compact(rule.selector) : `@${rule.name} ${compact(rule.params ?? '')}`
    const detail = node.type === 'decl' ? `${node.prop}: ${compact(node.value)}` : compact(node.toString())
    findings.push({ key: JSON.stringify([file, kind, ancestry, selector, detail]), file, kind, line: node.source.start.line })
  }
  root.walkRules((rule) => {
    if (!/:hover\b/i.test(rule.selector)) return
    let gated = false
    for (let parent = rule.parent; parent; parent = parent.parent) {
      if (parent.type === 'atrule' && parent.name.toLowerCase() === 'media' && fineHover.test(parent.params) && !parent.params.includes(',') && !/\b(?:not|or)\b/i.test(parent.params)) gated = true
    }
    if (!gated) record(rule, 'hover')
  })
  root.walkDecls((decl) => {
    const prop = decl.prop.toLowerCase()
    const value = decl.value.toLowerCase()
    if (/(?:linear|radial|conic)-gradient\s*\(/.test(value)) record(decl, 'gradient')
    if (/^(?:-webkit-)?backdrop-filter$/.test(prop) && value !== 'none') record(decl, 'glass')
    // Focus rings, overlays and inset borders are explicitly documented in the
    // allowlist; all other non-none shadows fail, including variable aliases.
    if (prop === 'box-shadow' && value !== 'none') record(decl, 'shadow')
    const side = /^border-(?:left|right|inline(?:-start|-end)?)(?:-width)?$/.test(prop)
    const shorthand = prop === 'border' || prop === 'border-width'
    if ((side || shorthand) && thickSideBorder(prop, value)) record(decl, 'side-border')
  })
  return findings
}
