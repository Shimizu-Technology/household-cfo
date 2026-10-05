import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const __dirname = dirname(fileURLToPath(import.meta.url))
const app = readFileSync(resolve(__dirname, '../src/App.tsx'), 'utf8')
const adminConsole = readFileSync(resolve(__dirname, '../src/components/AdminConsole.tsx'), 'utf8')
const css = readFileSync(resolve(__dirname, '../src/App.css'), 'utf8')
const api = readFileSync(resolve(__dirname, '../src/api.ts'), 'utf8')
const home = readFileSync(resolve(__dirname, '../src/components/HomeScreen.tsx'), 'utf8')
const budgetVisuals = readFileSync(resolve(__dirname, '../src/components/BudgetVisuals.tsx'), 'utf8')
const budgetPosition = readFileSync(resolve(__dirname, '../src/lib/budgetPosition.ts'), 'utf8')
const participantTabs = readFileSync(resolve(__dirname, '../src/components/ParticipantTabs.tsx'), 'utf8')
const button = readFileSync(resolve(__dirname, '../src/components/Button.tsx'), 'utf8')
const chatHistory = readFileSync(resolve(__dirname, '../src/components/ChatHistory.tsx'), 'utf8')
const safeMessageText = readFileSync(resolve(__dirname, '../src/components/SafeMessageText.tsx'), 'utf8')
const coachStudio = readFileSync(resolve(__dirname, '../src/components/CoachStudio.tsx'), 'utf8')
const coachStudioCss = readFileSync(resolve(__dirname, '../src/components/CoachStudio.css'), 'utf8')
const coachSources = readFileSync(resolve(__dirname, '../src/components/CoachContentSources.tsx'), 'utf8')
const coachSourcesCss = readFileSync(resolve(__dirname, '../src/components/CoachContentSources.css'), 'utf8')
const coachUrlIntake = readFileSync(resolve(__dirname, '../src/components/CoachUrlSourceIntake.tsx'), 'utf8')
const personaDraft = readFileSync(resolve(__dirname, '../src/lib/personaDraft.ts'), 'utf8')
const demoHouseholdData = readFileSync(resolve(__dirname, '../../api/app/services/demo/household_data.rb'), 'utf8')
const html = readFileSync(resolve(__dirname, '../index.html'), 'utf8')
const brandContext = readFileSync(resolve(__dirname, '../src/contexts/BrandContext.tsx'), 'utf8')
const brandDocument = readFileSync(resolve(__dirname, '../src/components/BrandDocument.tsx'), 'utf8')

const expectedNav = "['Home', 'Review', 'Ask Mia', 'Budget', 'My Profile', 'Wealth', 'CFO Filter', 'Optionality']"
assert.ok(
  app.replace(/\s+/g, ' ').includes(expectedNav),
  'participant navigation must keep the complete set of participant modules',
)

assert.ok(!app.includes("'Dashboard'"), 'Dashboard label should be converted to Home')
assert.ok(!app.includes("'Cohort'"), 'Cohort/admin should not appear in participant nav')
assert.ok(app.includes('<h1>{brand.short_name}</h1>'), 'every participant destination should use the release-pinned product header')
assert.ok(!app.includes('compactShell'), 'participant destinations should not switch shell geometry')
assert.ok(app.includes('chat-prompts-cue') && app.includes('More prompts →'), 'Mia prompts should disclose horizontal choices')
assert.ok(css.includes('.chat-prompts-cue {\n    display: none;'), 'wrapped mobile prompts should not show a misleading horizontal-scroll cue')
assert.ok(css.includes('@media (prefers-reduced-motion: reduce)'), 'screen motion should respect reduced-motion preferences')
assert.ok(home.includes('home-detail-disclosure'), 'Home should progressively disclose deeper annual-plan details')
assert.ok(app.includes('<ActivityPreview'), 'demo Review should provide a useful plan view instead of a dead end')
assert.ok(app.includes('resizeMiaComposer'), 'Mia composer should grow and shrink with typed or programmatically inserted text')
assert.ok(css.includes('max-height: 160px') && css.includes('overflow-y: hidden'), 'Mia composer should cap before switching to internal scrolling')
assert.ok(html.includes('<meta name="mobile-web-app-capable" content="yes" />'), 'installable mobile app markup should use the current capability flag')
assert.ok(css.includes('.shell-brand h1') && css.includes('.home-welcome-panel'), 'the stable shell should keep Home-specific coaching content inside Home')
assert.ok(app.includes('brand.welcome_heading') && app.includes('brand.welcome_description'), 'Home should use the coach-configured welcome copy')
assert.ok(brandContext.includes('fetchPublicBrand(hostname') && brandDocument.includes("'--brand-on-primary'"), 'public bootstrap and runtime document styling should use the resolved brand')
assert.ok(html.includes('<title>VERA</title>') && !html.includes('Mia'), 'static metadata should remain neutral until a hostname brand resolves')
for (const rejectedCopy of [
  'Mia, your household CFO.',
  'Plan, don’t gamble.',
  "Plan, don't gamble.",
  'Your money picture, without the spiral.',
  'Annual runway first. Monthly moves second.',
]) {
  assert.ok(!app.includes(rejectedCopy), `App should not include rejected UI copy: ${rejectedCopy}`)
}
assert.ok(home.includes('data-page-heading') && home.includes('CFO snapshot</h2>'), 'home copy should keep a focusable section heading')
assert.ok(home.includes('What needs review?'), 'home should lead with pending review work')
assert.ok(budgetVisuals.includes('Month-to-date inside the annual plan'), 'home should connect the current month to the annual plan')
assert.ok(home.includes('Your path from Red to Yellow to Green'), 'home should explain the deterministic readiness progression')
assert.ok(home.includes("current_runway_months === null ? 'Not available'") && home.includes("monthly_surplus === null ? 'Not available'"), 'home readiness must not render unknown runway or surplus as zero')
assert.ok(home.includes('<CategoryPressureList'), 'home should rank the categories needing attention')
assert.ok(home.includes('<AnnualCashFlowChart'), 'home should show the annual plan as an income-versus-outflow chart')
assert.ok(home.includes('selectedMonthIndex={currentMonthIndex}'), 'home cash flow should open on the current report month')
assert.ok(budgetVisuals.includes('cash-flow-detail-panel'), 'shared cash-flow charts should expose a readable exact-value panel')
assert.ok(budgetVisuals.includes("activeMonth.period_id === reportPeriodId ? 'Report month' : 'Chart preview'"), 'cash-flow detail should distinguish the report month from an interactive chart preview')
assert.ok(budgetVisuals.includes("aria-current={month.period_id === reportPeriodId ? 'date' : undefined}"), 'cash-flow charts should expose the report month to assistive technology')
assert.ok(app.includes('selectedBudgetOutlookMonth?.planned_outflow ?? budgetForView.total_monthly_outflow'), 'Budget headline outflow must follow the selected report month')
assert.ok(app.includes('<AnnualOutlookPanel plan={plan} selectedMonthIndex={currentMonthIndex} />'), 'Budget annual cash flow should stay synchronized with the report selector')
assert.ok(css.includes('.budget-period-summary .metric-row'), 'Budget report-month metrics should use a complete three-column hierarchy')
assert.ok(css.includes('.cash-flow-month.is-report-month'), 'cash-flow charts should visibly mark the report month')
assert.ok(budgetVisuals.includes('Expected irregular plan included in outflow'), 'selected cash-flow months should explain the irregular plan behind their totals')
assert.ok(budgetVisuals.includes('expected_contributors.map'), 'selected cash-flow months should list their expected irregular contributors')
assert.ok(budgetVisuals.includes('Pilot guardrail: 40% of positive baseline surplus in Yellow or Green—not ordinary budget remaining.'), 'safe to spend must disclose its provisional formula and remain distinct from ordinary plan remaining')
assert.ok(budgetVisuals.includes('pending review—not included in actuals.'), 'pending activity must remain visibly outside confirmed actuals')
assert.ok(budgetVisuals.includes('const titleId = useId()'), 'reusable cockpit panels should generate unique accessible heading IDs')
assert.ok(!budgetVisuals.includes('id="category-pressure-title"'), 'category panels should not reuse a hardcoded heading ID')
assert.ok(budgetPosition.includes('pendingAmountsByCategory'), 'monthly cockpit should derive pending amounts without adding them to actuals')
assert.ok(budgetPosition.includes('transactionDraftBudgetImpacts'), 'transaction review should derive its category impact from the annual plan')
assert.ok(
  participantTabs.includes('aria-expanded={moreOpen}') && participantTabs.includes('role="dialog"') && participantTabs.includes('aria-modal="true"'),
  'secondary modules should open from an accessible Tools control',
)
assert.ok(participantTabs.includes('tabs-tools-backdrop') && css.includes('position: fixed;'), 'mobile Tools should overlay content instead of expanding the navigation layout')
assert.ok(participantTabs.includes('<a') && participantTabs.includes('href={sectionHref(section)}'), 'participant destinations should keep native link semantics')
assert.ok(app.includes("addEventListener('popstate'") && app.includes("scrollRestoration = 'manual'"), 'participant routing should support browser history and route-keyed scroll restoration')
assert.ok(app.includes('canResumePlaidOAuthReturn') && app.includes('readPlaidOAuthSession') && app.includes('clearPlaidOAuthStateFromUrl'), 'Plaid returns should lock only while a stored callback is resumable')
assert.ok(app.includes('[data-page-heading]') && app.includes('focus({ preventScroll: true })'), 'section navigation should move focus to the new page heading')
assert.ok(!css.includes('transform: translateY(7px)'), 'page entry motion should not transform the structural screen ancestor')
assert.ok(button.includes("variant?: 'primary' | 'secondary' | 'ghost' | 'danger'"), 'shared button variants should fully define important action states')
assert.ok(css.includes('.button--secondary,\n.secondary-button'), 'legacy secondary actions should receive complete shared styling')
assert.ok(css.includes('.tabs-shell {\n  position: sticky;'), 'the participant navigation shell should stay available while scrolling')
assert.ok(css.includes('.income-schedule-form :where(input, select)'), 'income schedule controls should share the application input styling')
assert.ok(css.includes('.income-schedule-submit'), 'income timeline changes should use an intentional primary action style')
assert.ok(css.includes('.income-schedule-form-footer'), 'income timeline actions should sit in a balanced full-width footer')
assert.ok(app.includes('Plan preview'), 'income timeline edits should explain their effect before saving')
assert.ok(app.includes("current_runway_months ?? 'Not available'") && app.includes("current_runway_months === null ? '' : ' months'"), 'optionality must render an unavailable runway without null copy')
assert.ok(app.includes('const trackingDirty =') && app.includes('disabled={saving || !trackingDirty}'), 'debt tracking save state should include both mode and summary edits')
assert.ok(app.includes('Schedule income change'), 'recurring income timeline actions should use a specific action label')
assert.ok(app.includes('Budget impact if approved'), 'transaction review cards should show the pending category impact before confirmation')
assert.ok(css.includes('white-space: nowrap'), 'financial values should stay intact instead of breaking digits across lines')

assert.ok(budgetVisuals.includes('<span>Expense Stack</span>'), 'the visible budget cockpit should identify the Expense Stack framework')
for (const stackLabel of ['Non-discretionary', 'Sinking Fund — Expected', 'Sinking Fund — Unexpected']) {
  assert.ok(budgetVisuals.includes(stackLabel), `the visible budget cockpit should include the ${stackLabel} fallback label`)
}
assert.ok(app.includes('demoUploads.map') && app.includes('<h3>{upload.label}</h3>'), 'the visible demo Profile should render every approved upload label')
for (const uploadLabel of ['Upload spreadsheet', 'Upload statement', 'Upload pay stub']) {
  assert.ok(demoHouseholdData.includes(`label: "${uploadLabel}"`), `the demo API should supply the visible ${uploadLabel} card`)
}
assert.ok(app.includes('Approved data loaded'), 'the visible workspace status should identify approved data')
assert.ok(!app.includes('Source-derived design requirements'), 'production accessibility output must not contain test-only source copy')

for (const token of ['--cream', '--ink', '--ink-soft', '--paper-deep', '--emerald', '--berry', '--font-display', '--serif-font', '--status-green', '--status-yellow', '--status-red']) {
  assert.ok(css.includes(token), `CSS should include cleaned design token ${token}`)
}
assert.ok(css.includes('.insight-card.red,'), 'critical dashboard alerts should carry the same red visual status as other red financial cards')
assert.ok(app.includes('onUnsavedChangesChange'), 'unsaved budget changes must be communicated to participant navigation')
assert.ok(app.includes('Try again'), 'an initial workspace loading failure should offer a real recovery action')
assert.ok(chatHistory.includes('<SafeMessageText') && safeMessageText.includes('<ul') && safeMessageText.includes('<strong key='), 'Mia answers should preserve safe semantic lists and emphasis')

assert.ok(css.includes('--emerald: #7b4a58'), 'primary brand token should shift from green to deep mauve')
assert.ok(css.includes('--emerald-soft: #f1e2e3'), 'soft brand token should use dusty rose')
assert.ok(!css.includes('#0f4c3a'), 'old masculine green should not remain in main app CSS')

for (const structuredControl of [
  '<ChoiceChips label="Tone traits"',
  '<SelectChoice label="Energy"',
  '<SelectChoice label="Accountability style"',
  '<ChoiceChips label="Language style"',
]) {
  assert.ok(coachStudio.includes(structuredControl), `Persona Studio should use structured voice control ${structuredControl}`)
}
assert.ok(!coachStudio.includes('<LineList label="Tone traits"'), 'tone traits must not accept free-form style instructions')
assert.ok(!coachStudio.includes('<TextInput label="Energy"'), 'persona energy must not accept free-form style instructions')
assert.ok(coachStudio.includes('State a safe boundary without quoting or embedding cultural mimicry.'), 'Do not help must explain that embedded mimicry is still rejected')
assert.ok(
  coachStudio.includes('ref={errorAlertRef}')
    && coachStudio.includes('ref={conflictAlertRef}')
    && coachStudio.includes('role="alert" tabIndex={-1}'),
  'Coach Studio mutation errors and conflicts should be programmatically focusable alerts',
)
assert.ok(
  coachStudio.includes("alert.scrollIntoView({ block: 'center' })")
    && coachStudio.includes('alert.focus({ preventScroll: true })'),
  'Coach Studio should move mutation feedback into view and focus it',
)
assert.ok(coachStudio.includes('void loadPersonas(selectedPersona?.id)'), 'Coach Studio errors should preserve their retry action')
assert.ok(
  coachStudio.includes("capability?.can_edit === true")
    && coachStudio.includes("capability?.can_move === true")
    && coachStudio.includes("capability?.can_remove === true"),
  'sealed phrase controls should use server-provided mutation capabilities',
)
assert.ok(
  coachStudio.includes('aria-label="Locked phrase"')
    && coachStudio.includes('<span>{sourceLabel}</span>')
    && coachStudio.includes('{lockedReason}')
    && coachStudio.includes('Only the owning coach can add or change approved phrases.'),
  'Coach Studio should expose accessible provenance, locked, and ownership states',
)
assert.ok(
  coachStudio.includes('disabled={!canEdit}')
    && coachStudio.includes('disabled={!canMove || index === 0}')
    && coachStudio.includes('disabled={!canRemove}'),
  'locked phrase fields and actions should remain disabled on desktop and mobile',
)
assert.ok(
  coachStudioCss.includes('.coach-phrase-provenance') && coachStudioCss.includes('flex-wrap: wrap'),
  'phrase provenance and lock labels should wrap instead of overflowing narrow mobile cards',
)
assert.ok(personaDraft.includes("'Use light humor only when the situation is not sensitive.'"), 'reviewed voice choices should include situational light humor')
assert.ok(personaDraft.includes("'Keep the tone professional and formal.'"), 'reviewed voice choices should include formal language')
assert.ok(coachSources.includes('<CoachUrlSourceIntake'), 'private source review should offer secure web intake alongside file upload')
assert.ok(coachUrlIntake.includes('Private snapshot') && coachUrlIntake.includes('Addresses stay hidden after submission'), 'secure web intake should explain snapshot privacy and redaction')
assert.ok(coachUrlIntake.includes("type=\"url\"") && coachUrlIntake.includes("inputMode=\"url\""), 'secure web intake should use an accessible mobile URL keyboard')
assert.ok(coachSourcesCss.includes('.coach-source-create-grid') && coachSourcesCss.includes('@media (max-width: 400px)'), 'source intake should define desktop and compact mobile layouts')
assert.ok(coachSourcesCss.includes('.coach-url-intake-actions .button') && coachSourcesCss.includes('width: 100%'), 'secure intake actions should become full-width touch targets on compact phones')

assert.ok(api.includes('budget'), 'API client type should expose budget data')
assert.ok(api.includes('wealth'), 'API client type should expose wealth data')
assert.ok(
  adminConsole.includes('requestedCohortId === null') && adminConsole.includes('selectedCohortIdRef = useRef<number | null | undefined>'),
  'admin All users selection should survive reloads after save/resend actions',
)
assert.ok(adminConsole.includes("useState<UserStatusFilter>('active')"), 'admin users should default to active-only filtering')
assert.ok(adminConsole.includes('Send invite email now'), 'admin invite form should make email delivery explicit')
assert.ok(adminConsole.includes('filterAndSortAdminUsers'), 'admin users should have filter/sort controls')
assert.ok(adminConsole.includes('serverCohortIdsForUser(user).filter'), 'admin quick actions should use server-confirmed cohort state, not unsaved drafts')
assert.ok(!adminConsole.includes('setup_complete_count: memberships.filter'), 'admin cohort cards should not override server setup-complete counts client-side')
// Delayed/failing year selection and stale workspace responses are exercised in
// the BOG UI budget-year browser regressions rather than pinning rollback syntax.
assert.ok(app.includes('Search merchant, category, date, or amount'), 'large transaction review queues should be searchable')
assert.ok(app.includes('Remove original file keeps this history and extracted results.'), 'source deletion should clearly preserve the import record')
assert.ok(app.includes('Delete upload & record removes the original file and this entire import history.'), 'full import deletion should clearly describe its larger scope')
assert.ok(!app.includes("'Delete source'"), 'ambiguous source deletion label should not return')
assert.ok(!app.includes("'Delete import'"), 'ambiguous import deletion label should not return')
assert.ok(app.includes('if (!metadata.routing_source) return null'), 'routing status should remain hidden until extraction records a routing decision')
assert.ok(app.includes("if (destination === 'private_document_review') return 'Private document history'"), 'an explicit private routing destination should override document-kind fallback labels')
assert.ok(!app.includes("destination === 'transaction_review' || kind"), 'destination labels should resolve explicit backend metadata before falling back to document kind')
assert.ok(chatHistory.includes('const effectiveStatus = documentImport?.status ?? attachment.status'), 'chat attachment actions should prefer the live import status over the historical message snapshot')
assert.ok(chatHistory.includes("effectiveStatus === 'needs_review'"), 'chat attachment review labels should use the effective live status')
assert.ok(!chatHistory.includes("attachment.status === 'needs_review'"), 'historical attachment status should not directly control the current action label')
assert.ok(app.includes('Page {safePage + 1} of {totalPages}'), 'large transaction review queues should paginate instead of filling the page')
assert.ok(app.includes('Confirm categorized {confirmableDrafts.length}'), 'pending review queues should bulk-confirm only intentionally categorized transactions')
assert.ok(app.includes('Ignore all {filteredPendingDrafts.length}'), 'pending review queues should expose bulk ignore')
assert.ok(app.includes('const phrase = `CONFIRM ${ids.length}`'), 'bulk actuals updates should require the exact typed count phrase')
assert.ok(css.includes('.transaction-draft-queue-controls'), 'transaction review queue controls should have intentional responsive styling')
assert.ok(css.includes('.transaction-draft-bulk-actions'), 'bulk transaction controls should have intentional styling')
assert.ok(css.includes('.budget-progress-pending'), 'pending budget amounts should have a visually separate progress treatment')
assert.ok(css.includes('.annual-cash-flow-scroll'), 'annual cash-flow charts should have an intentional mobile scroll region')
assert.ok(app.includes('function updateIncomeDraft(values: Partial<IncomeScheduleDraft>)'), 'annual income edits should copy input values before React releases the event')
assert.ok(
  !/setDraft\(\(current\)[^\n]*event\.currentTarget/.test(app),
  'React event values must not be read from a deferred annual-income state updater',
)

console.log('design regression checks passed')
