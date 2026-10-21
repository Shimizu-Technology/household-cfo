import postcss from 'postcss'

const compact = (value) => value.replace(/\s+/g, ' ').trim()
const fineHover = /\(hover:\s*hover\)\s+and\s+\(pointer:\s*fine\)/

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
    if (!rule.selector.includes(':hover')) return
    let gated = false
    for (let parent = rule.parent; parent; parent = parent.parent) {
      if (parent.type === 'atrule' && parent.name === 'media' && fineHover.test(parent.params) && !parent.params.includes(',') && !/\bnot\b/.test(parent.params)) gated = true
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
    if ((side || shorthand) && (/\b(?:medium|thick)\b/.test(value) || /^var\(/.test(value) || [...value.matchAll(/([\d.]+)(px|rem|em)\b/g)].some((match) => Number(match[1]) * (match[2] === 'px' ? 1 : 16) > 1))) record(decl, 'side-border')
  })
  return findings
}
