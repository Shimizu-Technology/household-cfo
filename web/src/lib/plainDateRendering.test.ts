import { readdirSync, readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import ts from 'typescript'
import { expect, it } from 'vitest'

it('formats calendar dates and timestamps before showing participant or coach text', () => {
  const directory = fileURLToPath(new URL('../components/', import.meta.url))
  const files = readdirSync(directory).filter(name => name.endsWith('.tsx') && !name.includes('.test.')).map(name => directory + name)
  files.push(fileURLToPath(new URL('../App.tsx', import.meta.url)))
  const raw: string[] = []
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
  for (const file of files) {
    const source = ts.createSourceFile(file, readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
    function visit(node: ts.Node) {
      // Input values, machine-readable datetime attributes and API payloads remain ISO.
      if (ts.isJsxExpression(node) && !ts.isJsxAttribute(node.parent) && node.expression && unformatted(node.expression)) {
        raw.push(`${file.split('/').at(-1)}:${source.getLineAndCharacterOfPosition(node.pos).line + 1}: ${node.expression.getText(source)}`)
      }
      ts.forEachChild(node, visit)
    }
    visit(source)
  }
  expect(raw).toEqual([])
})
