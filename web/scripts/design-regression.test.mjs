import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

import { cssPolicyFindings } from './design-css-policy.mjs'
import { cssPolicyAllowlist } from './design-css-allowlist.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const app = readFileSync(resolve(__dirname, '../src/App.tsx'), 'utf8')
const incomePlanner = readFileSync(resolve(__dirname, '../src/components/AnnualIncomePlanner.tsx'), 'utf8')
const incomeSources = readFileSync(resolve(__dirname, '../src/components/IncomeSourceManager.tsx'), 'utf8')
const adminConsole = readFileSync(resolve(__dirname, '../src/components/AdminConsole.tsx'), 'utf8')
const css = readFileSync(resolve(__dirname, '../src/App.css'), 'utf8')
const api = readFileSync(resolve(__dirname, '../src/api.ts'), 'utf8')
const home = readFileSync(resolve(__dirname, '../src/components/HomeScreen.tsx'), 'utf8')
const budgetVisuals = readFileSync(resolve(__dirname, '../src/components/BudgetVisuals.tsx'), 'utf8')
const budgetPosition = readFileSync(resolve(__dirname, '../src/lib/budgetPosition.ts'), 'utf8')
const participantTabs = readFileSync(resolve(__dirname, '../src/components/ParticipantTabs.tsx'), 'utf8')
const button = readFileSync(resolve(__dirname, '../src/components/Button.tsx'), 'utf8')
const participantNavigation = readFileSync(resolve(__dirname, '../src/lib/participantNavigation.ts'), 'utf8')
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
const assistPanel = readFileSync(resolve(__dirname, '../src/components/MiaAssistPanels.tsx'), 'utf8')
const assistCss = readFileSync(resolve(__dirname, '../src/components/MiaAssistPanels.css'), 'utf8')

const expectedNav = "['Home', 'Review', 'Ask Mia', 'My Money', 'Budget', 'My Profile', 'Wealth', 'CFO Filter', 'Optionality']"
assert.ok(
  participantNavigation.replace(/\s+/g, ' ').includes(expectedNav) && app.includes('const sections = PARTICIPANT_SECTIONS'),
  'participant navigation must keep the complete set of participant modules',
)

assert.ok(!app.includes("'Dashboard'"), 'Dashboard label should be converted to Home')
assert.ok(!app.includes("'Cohort'"), 'Cohort/admin should not appear in participant nav')
assert.ok(app.includes('<h1>{brand.short_name}</h1>'), 'every participant destination should use the release-pinned product header')
assert.ok(!app.includes('compactShell'), 'participant destinations should not switch shell geometry')
assert.ok(assistPanel.includes('Update my information') && assistPanel.includes('Ask a question') && app.includes('onChoosePrompt={prepareMiaUpdate}'), 'Mia prompt groups should use consistent prepare-first behavior')
assert.ok(!assistPanel.includes('More prompts') && assistCss.includes('.mia-assist-prompts { display: grid'), 'all prompt choices should be visible without a misleading horizontal cue')
assert.ok(css.includes('@media (prefers-reduced-motion: reduce)'), 'screen motion should respect reduced-motion preferences')
assert.ok(home.includes('home-readiness-details') && home.includes('home-plan-link'), 'Home keeps readiness details and plan navigation below the visible year')
assert.ok(app.includes('<ActivityPreview'), 'demo Review should provide a useful plan view instead of a dead end')
assert.ok(app.includes('resizeMiaComposer'), 'Mia composer should grow and shrink with typed or programmatically inserted text')
assert.ok(css.includes('max-height: 160px') && css.includes('overflow-y: hidden'), 'Mia composer should cap before switching to internal scrolling')
assert.ok(html.includes('<meta name="mobile-web-app-capable" content="yes" />'), 'installable mobile app markup should use the current capability flag')
assert.ok(css.includes('.shell-brand h1') && css.includes('.home-welcome-panel'), 'the stable shell should keep Home-specific coaching content inside Home')
assert.ok(app.includes('Set up with {assistantName}') && !home.includes('command center'), 'Household Home should offer one setup route without repeating a marketing promise')
assert.ok(brandContext.includes('fetchPublicBrand(hostname') && brandDocument.includes("'--brand-on-primary'"), 'public bootstrap and runtime document styling should use the resolved brand')
assert.ok(html.includes('<title>Household CFO</title>') && !html.includes('Mia'), 'static metadata should use the consumer brand without naming an assistant until a hostname brand resolves')
assert.ok(!/VERA/.test(html) && !/VERA/.test(readFileSync(new URL('../public/manifest.webmanifest', import.meta.url), 'utf8')), 'participants never see the internal platform name in static metadata')
for (const rejectedCopy of [
  'Mia, your household CFO.',
  'Plan, don’t gamble.',
  "Plan, don't gamble.",
  'Your money picture, without the spiral.',
  'Annual runway first. Monthly moves second.',
]) {
  assert.ok(!app.includes(rejectedCopy), `App should not include rejected UI copy: ${rejectedCopy}`)
}
assert.ok(home.includes('data-page-heading') && home.includes('Home</h2>'), 'Home should retain its focusable page heading')
assert.ok(home.includes('Review ${purchaseCount}') && home.includes('Tell ${assistantName} what changed'), 'Home should choose one next action')
assert.ok(budgetVisuals.includes('Money in') && budgetVisuals.includes('Planned out') && budgetVisuals.includes('Spent so far'), 'the money answer should lead: money in, money out')
assert.ok(!budgetVisuals.includes('Left in the plan'), 'planned spending not yet used must not read as money left over')
assert.ok(home.includes('home-readiness-details'), 'readiness explanation should remain reachable')
assert.ok(home.includes('<AnnualCashFlowChart') && home.includes('selectedMonthIndex={monthIndex}'), 'Home should expose the year with the current month selected')
assert.ok(budgetVisuals.includes('cash-flow-detail-panel'), 'shared cash-flow charts should expose a readable exact-value panel')
assert.ok(budgetVisuals.includes("activeMonth.period_id === reportPeriodId ? 'Report month' : 'Chart preview'"), 'cash-flow detail should distinguish the report month from an interactive chart preview')
assert.ok(budgetVisuals.includes("aria-current={month.period_id === reportPeriodId ? 'date' : undefined}"), 'cash-flow charts should expose the report month to assistive technology')
assert.ok(app.includes('income={currentMonthIncome}'), 'Budget money should follow the selected report month')
assert.ok(app.includes('<AnnualOutlookPanel plan={plan} selectedMonthIndex={currentMonthIndex} moneyKnown='), 'Budget annual cash flow should stay synchronized with the report selector')
assert.ok(css.includes('.budget-period-summary .metric-row'), 'Budget report-month metrics should use a complete three-column hierarchy')
assert.ok(css.includes('.cash-flow-month.is-report-month'), 'cash-flow charts should visibly mark the report month')
assert.ok(budgetVisuals.includes('Expected irregular plan included in outflow'), 'selected cash-flow months should explain the irregular plan behind their totals')
assert.ok(budgetVisuals.includes('expected_contributors.map'), 'selected cash-flow months should list their expected irregular contributors')
assert.ok(!budgetVisuals.includes('Safe to spend'), 'the month summary should keep one meaning for plan remaining')
assert.ok(budgetVisuals.includes('pending review—not included in actuals.'), 'pending activity must remain visibly outside confirmed actuals')
assert.ok(budgetVisuals.includes('const titleId = useId()'), 'reusable cockpit panels should generate unique accessible heading IDs')
assert.ok(!budgetVisuals.includes('id="category-pressure-title"'), 'category panels should not reuse a hardcoded heading ID')
assert.ok(budgetPosition.includes('pendingAmountsByCategory'), 'monthly cockpit should derive pending amounts without adding them to actuals')
assert.ok(budgetPosition.includes('transactionDraftBudgetImpacts'), 'transaction review should derive its category impact from the annual plan')
assert.ok(
  participantTabs.includes('aria-expanded={moreOpen}') && participantTabs.includes('role="dialog"') && participantTabs.includes('aria-modal="true"'),
  'secondary modules should open from an accessible More control',
)
assert.ok(participantTabs.includes('tabs-tools-backdrop') && css.includes('position: fixed;'), 'mobile More should overlay content instead of expanding the navigation layout')
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
assert.ok(incomePlanner.includes('income-schedule-preview') && incomePlanner.includes('{previewCopy}'), 'income timeline edits should explain their effect before saving')
assert.ok(app.includes("current_runway_months ?? 'Not available'") && app.includes("current_runway_months === null ? '' : ' months'"), 'optionality must render an unavailable runway without null copy')
assert.ok(app.includes('const trackingDirty =') && app.includes('disabled={saving || formDirty || !trackingDirty}'), 'debt tracking save state should include both mode and summary edits')
assert.ok(incomePlanner.includes('Schedule income change'), 'recurring income timeline actions should use a specific action label')
assert.ok(app.includes('Budget impact if approved'), 'transaction review cards should show the pending category impact before confirmation')
assert.ok(css.includes('white-space: nowrap'), 'financial values should stay intact instead of breaking digits across lines')

assert.ok(budgetVisuals.includes('Where the money goes'), 'the budget groups should explain the spending plan in everyday words')
for (const stackLabel of ['Must-pay bills', 'Flexible spending', 'Planned yearly costs', 'Surprise fund']) {
  assert.ok(budgetVisuals.includes(stackLabel), `the visible budget cockpit should include the ${stackLabel} fallback label`)
}
assert.ok(app.includes('demoUploads.map') && app.includes('<h3>{upload.label}</h3>'), 'the visible demo Profile should render every approved upload label')
for (const uploadLabel of ['Upload spreadsheet', 'Upload statement', 'Upload pay stub']) {
  assert.ok(demoHouseholdData.includes(`label: "${uploadLabel}"`), `the demo API should supply the visible ${uploadLabel} card`)
}
assert.ok(assistPanel.includes('Your saved picture') && app.includes('Your saved household plan'), 'workspace help should identify saved data without implying missing values are complete')
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

assert.ok(css.includes('background: var(--pending-hatch)') && css.includes('--pending-hatch: url("data:image/svg+xml,'), 'pending money and its legend keep the same non-gradient hatch')

// The first CSS paint and React's safe fallback share every BrandDocument
// legacy alias. A resolved/persisted release may still supply its own palette.
const fallbackSource = readFileSync(resolve(__dirname, '../src/contexts/brandContextValue.ts'), 'utf8')
const fallbackColors = fallbackSource.match(/colors: \{([\s\S]*?)\n  \}/)[1]
const rootTokens = css.match(/^:root \{([\s\S]*?)\n\}/)[1]
for (const [token, field] of Object.entries({
  cream: 'background', paper: 'surface', 'paper-warm': 'surface_muted', 'paper-deep': 'surface_muted',
  ink: 'text', 'ink-soft': 'text_muted', muted: 'text_muted', line: 'border',
  emerald: 'primary', mauve: 'primary', berry: 'primary_hover', 'emerald-soft': 'primary_soft',
  gold: 'accent', plum: 'text', 'brand-on-primary': 'on_primary', 'brand-primary-hover': 'primary_hover', 'brand-focus': 'focus',
})) {
  const value = fallbackColors.match(new RegExp(`\\b${field}: '([^']+)'`))[1]
  assert.ok(rootTokens.includes(`--${token}: ${value};`), `fallback ${field} must agree with CSS --${token}`)
}
assert.ok(fallbackSource.includes("typography: { display: 'cormorant_garamond', body: 'montserrat' }"), 'fallback keeps the approved brand typography')
assert.ok(rootTokens.includes('--font-body: Montserrat, ui-sans-serif, system-ui, sans-serif;'), 'CSS body fallback matches BrandDocument montserrat')
assert.ok(rootTokens.includes('--number-font: Montserrat, ui-sans-serif, system-ui, sans-serif;'), 'money uses the body face')
assert.ok(rootTokens.includes('--font-display: "Cormorant Garamond", Georgia, serif;'), 'CSS display fallback matches BrandDocument cormorant')

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
// Bulk confirm is all-or-nothing: the exact typed "CONFIRM N" phrase is required in the in-app dialog before the bulk call.
assert.ok(app.includes('const phrase = `CONFIRM ${count}`'), 'the bulk confirm dialog should build the exact count phrase')
assert.ok(app.includes('const mismatch = bulkConfirmPhraseMismatchMessage(count, typed)'), 'the bulk confirm dialog should compare the typed text with the exact phrase')
assert.ok(/if \(mismatch\) \{\s*setProblem\(mismatch\)\s*return\s*\}\s*onConfirm\(\)/.test(app), 'a wrong phrase must stop in the dialog before onConfirm runs')
assert.ok(app.includes("if (resolution === 'confirm' && !confirmed) {"), 'bulk confirm must go through the typed-phrase dialog before running')
assert.ok(app.includes('setBulkConfirmRequest({ drafts: pendingDrafts, total })'), 'bulk confirm should open the dialog instead of calling the API directly')
assert.ok(app.includes('bulkConfirmTransactionDrafts(ids, selectedBudgetYear, `CONFIRM ${ids.length}`'), 'the bulk confirm API call should send the exact count phrase')
assert.ok(!app.includes('window.prompt('), 'bulk confirm should not use the native prompt')
assert.ok(css.includes('.transaction-draft-queue-controls'), 'transaction review queue controls should have intentional responsive styling')
assert.ok(css.includes('.transaction-draft-bulk-actions'), 'bulk transaction controls should have intentional styling')
assert.ok(css.includes('.budget-progress-pending'), 'pending budget amounts should have a visually separate progress treatment')
assert.ok(css.includes('.annual-cash-flow-scroll'), 'annual cash-flow charts should have an intentional mobile scroll region')
assert.ok(incomePlanner.includes('function updateIncomeDraft(values: Partial<IncomeScheduleDraft>)'), 'annual income edits should copy input values before React releases the event')
assert.ok(
  !/setDraft\(\(current\)[^\n]*event\.currentTarget/.test(app + incomePlanner + incomeSources),
  'React event values must not be read from a deferred annual-income state updater',
)

function stylesheets(directory) {
  return readdirSync(resolve(__dirname, directory), { withFileTypes: true }).flatMap((entry) => {
    const file = `${directory}/${entry.name}`
    return entry.isDirectory() ? stylesheets(file) : entry.name.endsWith('.css') ? [file] : []
  })
}
const stylesheetFiles = stylesheets('../src')
for (const file of stylesheetFiles) {
  const source = readFileSync(resolve(__dirname, file), 'utf8')
  for (const block of source.match(/@font-face\s*\{[^}]*\}/g) ?? []) {
    assert.ok(!block.includes('var('), `${file}: @font-face descriptors must be literal values, not custom properties`)
  }
}

// Exercise the policy itself so an accidentally weakened scanner cannot pass.
for (const [sample, kind] of [
  ['.card { background: linear-gradient(red, blue) }', 'gradient'],
  ['.card { backdrop-filter: blur(4px) }', 'glass'],
  ['.card { box-shadow: var(--shadow-sm) }', 'shadow'],
  ['.card { border-inline-start: 4px solid red }', 'side-border'],
  ['.card { border: 2px solid red }', 'side-border'],
  ['.card { border-left: 2pt solid red }', 'side-border'],
  ['.card { border-right: solid red var(--accent-width) }', 'side-border'],
  ['.card { border-inline-start: solid red }', 'side-border'],
  ['.card { border-left-width: calc(1px + 1px) }', 'side-border'],
  ['.card { border-left: 0.1em solid red }', 'side-border'],
  ['.card:hover { color: red }', 'hover'],
  ['.card:HOVER { color: red }', 'hover'],
  ['@media (hover: hover) { .card:hover { color: red } }', 'hover'],
  ['@media (width >= 0px) or ((hover: hover) and (pointer: fine)) { .card:hover { color: red } }', 'hover'],
  ['/* gradient(red, blue) */ .card { background: radial-gradient(red, blue) }', 'gradient'],
]) assert.ok(cssPolicyFindings(sample, 'fixture.css').some((finding) => finding.kind === kind), `CSS policy must detect ${kind}`)
assert.deepEqual(cssPolicyFindings(`/* linear-gradient(red, blue) */
  .card { box-shadow: none; border-left: 1px solid var(--line); border-right: solid red 0.75pt; backdrop-filter: none }
  @media (max-width: 600px) { @media (hover: hover) and (pointer: fine) { .card:hover { color: red } } }
`, 'fixture.css'), [], 'comments, flat surfaces and nested fine-pointer hover are valid')
const cssPolicyFailures = []
const matchedAllowlistKeys = new Set()
for (const path of stylesheetFiles) {
  const file = path.replace('../', '')
  const source = readFileSync(resolve(__dirname, path), 'utf8')
  for (const finding of cssPolicyFindings(source, file)) {
    if (cssPolicyAllowlist.has(finding.key)) matchedAllowlistKeys.add(finding.key)
    else cssPolicyFailures.push(`${file}:${finding.line} ${finding.kind}: ${finding.key}`)
  }
}
assert.deepEqual(cssPolicyFailures, [], 'new CSS decoration/ungated hover: remove it or document a specific intentional exception')
assert.deepEqual([...cssPolicyAllowlist].filter((key) => !matchedAllowlistKeys.has(key)), [], 'stale CSS policy exceptions: remove keys whose finding no longer exists')
console.log('design regression checks passed')
