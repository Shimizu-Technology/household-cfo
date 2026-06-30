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
assert.ok(app.includes('<h1>Household CFO Method</h1>'), 'top-level copy should lead with the Household CFO Method product name')
assert.ok(app.includes('Run your home like the C-Suite'), 'hero copy should use Mrs. Mel’s transformation language')
for (const rejectedCopy of [
  'Mia, your household CFO.',
  'Plan, don’t gamble.',
  "Plan, don't gamble.",
  'Your money picture, without the spiral.',
  'Annual runway first. Monthly moves second.',
]) {
  assert.ok(!app.includes(rejectedCopy), `App should not include rejected UI copy: ${rejectedCopy}`)
}
assert.ok(app.includes('title="CFO snapshot"'), 'home copy should keep the section heading simple')

for (const requiredCopy of [
  'Expense Stack',
  'Non-discretionary',
  'Sinking Fund — Expected',
  'Sinking Fund — Unexpected',
  'Upload spreadsheet',
  'Upload statement',
  'Upload pay stub',
  'Approved data loaded',
]) {
  assert.ok(app.includes(requiredCopy), `App should include source-derived UI copy: ${requiredCopy}`)
}

for (const token of ['--cream', '--ink', '--emerald', '--status-green', '--status-yellow', '--status-red']) {
  assert.ok(css.includes(token), `CSS should include cleaned design token ${token}`)
}

assert.ok(css.includes('--emerald: #7b4a58'), 'primary brand token should shift from green to deep mauve')
assert.ok(css.includes('--emerald-soft: #f1e2e3'), 'soft brand token should use dusty rose')
assert.ok(!css.includes('#0f4c3a'), 'old masculine green should not remain in main app CSS')

assert.ok(api.includes('budget'), 'API client type should expose budget data')
assert.ok(api.includes('wealth'), 'API client type should expose wealth data')
assert.ok(
  app.includes('requestedCohortId === null') && app.includes('selectedCohortIdRef = useRef<number | null | undefined>'),
  'admin All users selection should survive reloads after save/resend actions',
)
assert.ok(app.includes("useState<UserStatusFilter>('active')"), 'admin users should default to active-only filtering')
assert.ok(app.includes('Send invite email now'), 'admin invite form should make email delivery explicit')
assert.ok(app.includes('filterAndSortAdminUsers'), 'admin users should have filter/sort controls')
assert.ok(app.includes('serverCohortIdsForUser(user).filter'), 'admin quick actions should use server-confirmed cohort state, not unsaved drafts')
assert.ok(!app.includes('setup_complete_count: memberships.filter'), 'admin cohort cards should not override server setup-complete counts client-side')

console.log('design regression checks passed')
