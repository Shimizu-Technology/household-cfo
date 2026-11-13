import assert from 'node:assert/strict'
import { readFileSync, existsSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import ts from 'typescript'

// Check the transitive runtime graph, not just AuthLanding's direct imports.
const root = resolve(import.meta.dirname, '../src')
const visited = new Set()
function visit(file) {
  if (visited.has(file)) return
  visited.add(file)
  const source = ts.createSourceFile(file, readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true)
  for (const node of source.statements) {
    if (!ts.isImportDeclaration(node) || !ts.isStringLiteral(node.moduleSpecifier)) continue
    const clause = node.importClause
    if (clause?.isTypeOnly) continue
    if (clause?.namedBindings && ts.isNamedImports(clause.namedBindings) && !clause.name && clause.namedBindings.elements.every(item => item.isTypeOnly)) continue
    const name = node.moduleSpecifier.text
    if (!name.startsWith('.') || name.endsWith('.css')) continue
    const stem = resolve(dirname(file), name)
    const target = [stem + '.ts', stem + '.tsx', resolve(stem, 'index.ts')].find(existsSync)
    assert.ok(target, `Resolve runtime import ${name} from ${file}`)
    visit(target)
  }
}
visit(resolve(root, 'components/AuthLanding.tsx'))
const allowed = new Set([
  'components/AuthLanding.tsx', 'components/AuthControls.tsx', 'components/Button.tsx',
  'components/BrandChrome.tsx', 'contexts/brandContextValue.ts', 'contexts/authContextValue.ts',
  'lib/assistantGreeting.ts', 'lib/assistantName.ts',
])
for (const file of visited) assert.ok(allowed.has(file.slice(root.length + 1)), `Landing must remain entry-only: ${file}`)
console.log(`landing runtime boundary passed (${visited.size} modules; no workspace imports)`)
