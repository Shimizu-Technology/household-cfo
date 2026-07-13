import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const __dirname = dirname(fileURLToPath(import.meta.url))
const app = readFileSync(resolve(__dirname, '../src/App.tsx'), 'utf8')
const css = readFileSync(resolve(__dirname, '../src/App.css'), 'utf8')
const api = readFileSync(resolve(__dirname, '../src/api.ts'), 'utf8')
const home = readFileSync(resolve(__dirname, '../src/components/HomeScreen.tsx'), 'utf8')
const participantTabs = readFileSync(resolve(__dirname, '../src/components/ParticipantTabs.tsx'), 'utf8')

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
assert.ok(home.includes('<h2>CFO snapshot</h2>'), 'home copy should keep the section heading simple')
assert.ok(home.includes('What needs review?'), 'home should lead with pending review work')
assert.ok(home.includes('Month-to-date inside the annual plan'), 'home should connect the current month to the annual plan')
assert.ok(home.includes('Your path from Red to Yellow to Green'), 'home should explain the deterministic readiness progression')
assert.ok(participantTabs.includes('Swipe for more'), 'mobile navigation should disclose that more modules are horizontally available')
assert.ok(css.includes('white-space: nowrap'), 'financial values should stay intact instead of breaking digits across lines')

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
assert.ok(
  app.includes('const previousBudgetView = budgetView') && app.includes('setBudgetView((current) => (') && app.includes('? previousBudgetView'),
  'budget year navigation must restore the previous view when loading a different year fails',
)
assert.ok(app.includes('Search merchant, category, date, or amount'), 'large transaction review queues should be searchable')
assert.ok(app.includes('Remove original file keeps this history and extracted results.'), 'source deletion should clearly preserve the import record')
assert.ok(app.includes('Delete upload & record removes the original file and this entire import history.'), 'full import deletion should clearly describe its larger scope')
assert.ok(!app.includes("'Delete source'"), 'ambiguous source deletion label should not return')
assert.ok(!app.includes("'Delete import'"), 'ambiguous import deletion label should not return')
assert.ok(app.includes('if (!metadata.routing_source) return null'), 'routing status should remain hidden until extraction records a routing decision')
assert.ok(app.includes("if (destination === 'private_document_review') return 'Private document history'"), 'an explicit private routing destination should override document-kind fallback labels')
assert.ok(!app.includes("destination === 'transaction_review' || kind"), 'destination labels should resolve explicit backend metadata before falling back to document kind')
assert.ok(app.includes('Page {safePage + 1} of {totalPages}'), 'large transaction review queues should paginate instead of filling the page')
assert.ok(app.includes('Confirm all {filteredPendingDrafts.length}'), 'pending review queues should expose bulk confirmation')
assert.ok(app.includes('Ignore all {filteredPendingDrafts.length}'), 'pending review queues should expose bulk ignore')
assert.ok(app.includes('const phrase = `CONFIRM ${ids.length}`'), 'bulk actuals updates should require the exact typed count phrase')
assert.ok(css.includes('.transaction-draft-queue-controls'), 'transaction review queue controls should have intentional responsive styling')
assert.ok(css.includes('.transaction-draft-bulk-actions'), 'bulk transaction controls should have intentional styling')
assert.ok(app.includes('function updateIncomeDraft(values: Partial<IncomeScheduleDraft>)'), 'annual income edits should copy input values before React releases the event')
assert.ok(
  !/setDraft\(\(current\)[^\n]*event\.currentTarget/.test(app),
  'React event values must not be read from a deferred annual-income state updater',
)

console.log('design regression checks passed')
