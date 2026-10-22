import { readdirSync, readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import ts from 'typescript'
import { expect, it } from 'vitest'

const HUMAN_ATTRIBUTES = new Set(['title', 'aria-label', 'aria-description', 'placeholder', 'alt'])

function unformatted(expression: ts.Expression): boolean {
  if (ts.isPropertyAccessExpression(expression)) return /_(on|at|date)$/.test(expression.name.text)
  if (ts.isBinaryExpression(expression)) {
    if (expression.operatorToken.kind === ts.SyntaxKind.QuestionQuestionToken) return unformatted(expression.left)
    if (expression.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken) return unformatted(expression.right)
    if (expression.operatorToken.kind === ts.SyntaxKind.BarBarToken) return unformatted(expression.left) || unformatted(expression.right)
  }
  if (ts.isConditionalExpression(expression)) return unformatted(expression.whenTrue) || unformatted(expression.whenFalse)
  if (ts.isTemplateExpression(expression)) return expression.templateSpans.some(span => unformatted(span.expression))
  return false
}

// Text children and human-facing attributes must be formatted. Input values,
// machine-readable dateTime attributes and API payloads remain ISO.
function rawDates(text: string, name: string): string[] {
  const source = ts.createSourceFile(name, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
  const raw: string[] = []
  function visit(node: ts.Node) {
    if (ts.isJsxExpression(node) && node.expression && unformatted(node.expression)) {
      const attribute = ts.isJsxAttribute(node.parent) ? node.parent.name.getText(source) : null
      if (attribute === null || HUMAN_ATTRIBUTES.has(attribute)) {
        raw.push(`${name}:${source.getLineAndCharacterOfPosition(node.pos).line + 1}: ${node.expression.getText(source)}`)
      }
    }
    ts.forEachChild(node, visit)
  }
  visit(source)
  return raw
}

it('flags raw dates in text and human-facing attributes, not in machine values', () => {
  const sample = `const a = <p title={row.created_at}>{row.updated_at}</p>
const b = <time dateTime={row.posted_on}>x</time>
const c = <input value={draft.effective_on} />
const d = <button aria-label={\`Open \${row.posted_on}\`}>Open</button>`
  expect(rawDates(sample, 'Sample.tsx')).toEqual([
    'Sample.tsx:1: row.created_at',
    'Sample.tsx:1: row.updated_at',
    'Sample.tsx:4: `Open ${row.posted_on}`',
  ])
})

it('formats calendar dates and timestamps before showing participant or coach text', () => {
  const directory = fileURLToPath(new URL('../components/', import.meta.url))
  const files = readdirSync(directory).filter(name => name.endsWith('.tsx') && !name.includes('.test.')).map(name => directory + name)
  files.push(fileURLToPath(new URL('../App.tsx', import.meta.url)))
  const raw = files.flatMap(file => rawDates(readFileSync(file, 'utf8'), file.split('/').at(-1)!))
  expect(raw).toEqual([])
})
