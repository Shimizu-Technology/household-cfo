import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const __dirname = dirname(fileURLToPath(import.meta.url))
const app = readFileSync(resolve(__dirname, '../src/App.tsx'), 'utf8')
const css = readFileSync(resolve(__dirname, '../src/App.css'), 'utf8')
const api = readFileSync(resolve(__dirname, '../src/api.ts'), 'utf8')

const expectedNav = "['Home', 'Ask Mia', 'My Profile', 'Budget', 'Wealth', 'CFO Filter', 'Optionality']"
assert.ok(
  app.replace(/\s+/g, ' ').includes(expectedNav),
  'participant nav must match Mel source order: Home, Ask Mia, My Profile, Budget, Wealth, CFO Filter, Optionality',
)

assert.ok(!app.includes("'Dashboard'"), 'Dashboard label should be converted to Home')
assert.ok(!app.includes("'Cohort'"), 'Cohort/admin should not appear in participant nav')

for (const requiredCopy of [
  'Expense Stack',
  'Non-discretionary',
  'Sinking Fund — Expected',
  'Sinking Fund — Unexpected',
  'Upload spreadsheet',
  'Upload statement',
  'Upload pay stub',
  'Context loaded',
]) {
  assert.ok(app.includes(requiredCopy), `App should include source-derived UI copy: ${requiredCopy}`)
}

for (const token of ['--cream', '--ink', '--emerald', '--status-green', '--status-yellow', '--status-red']) {
  assert.ok(css.includes(token), `CSS should include cleaned design token ${token}`)
}

assert.ok(api.includes('budget'), 'API client type should expose budget data')
assert.ok(api.includes('wealth'), 'API client type should expose wealth data')
assert.ok(
  app.includes('requestedCohortId === null') && app.includes('selectedCohortIdRef = useRef<number | null | undefined>'),
  'admin All users selection should survive reloads after save/resend actions',
)

console.log('design regression checks passed')
