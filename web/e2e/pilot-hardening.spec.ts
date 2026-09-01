import { expect, test, type Page } from '@playwright/test'

const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
const currentMonth = new Intl.DateTimeFormat('en-US', { month: 'long' }).format(new Date())
const currentShortMonth = new Intl.DateTimeFormat('en-US', { month: 'short' }).format(new Date())
const currentYear = new Date().getFullYear()

async function openSection(page: Page, name: string) {
  const section = page.getByRole('link', { name, exact: true })
  const tools = page.getByRole('button', { name: 'Tools', exact: true })
  await expect(tools).toBeVisible()
  if (!(await section.isVisible())) {
    await tools.click()
    await expect(section).toBeVisible()
  }
  await section.click()
  await expect(tools).toHaveAttribute('aria-expanded', 'false')
  await expect(page.locator('.tabs-tools-backdrop')).toHaveCount(0)
}

const profile = {
  household: { name: 'Pilot Household', stage: 'First cohort', location: 'Guam', primary_goal: 'Build a calm annual rhythm.' },
  coach: { name: 'Mia', role: 'AI coach', voice: 'Warm and direct' },
  members: [], priorities: [], completeness: 100, uploads: [], sections: [],
}

const dashboard = {
  summary: {
    monthly_income: 14_200, fixed_expenses: 6_000, flexible_spend: 1_500, debt_payments: 200,
    monthly_surplus_rate_percent: 38, runway_months: 0.5, next_safe_to_spend_amount: 0,
    readiness_tone: 'red', readiness_label: 'Red — pause and stabilize basics',
  },
  action_center: {
    transaction_review_count: 2, mia_action_review_count: 1, total_review_count: 3,
    current_month_label: currentMonth, current_month_index: new Date().getMonth(), current_year: currentYear,
  },
  coach_read: {
    title: 'Protect the baseline and build runway.',
    body: 'The household is Red because essential stability or runway is not protected yet.',
  },
  readiness_path: {
    current_runway_months: 0.5, target_runway_months: 6, protected_liquid_amount: 5_000, monthly_surplus: 4_795,
    yellow: { tone: 'yellow', runway_months: 3, protected_liquid_target: 28_215, protected_liquid_gap: 23_215, cash_flow_requirement: 'Nonnegative monthly cash flow', reached: false },
    green: { tone: 'green', runway_months: 6, protected_liquid_target: 56_430, protected_liquid_gap: 51_430, cash_flow_requirement: 'Positive monthly cash flow', reached: false },
  },
  accounts: [],
  alerts: [{ tone: 'red', title: 'Readiness', body: 'Red — pause and stabilize basics' }],
  next_steps: ['Protect fixed bills first.', 'Pause new wants and direct available surplus to runway.', 'Review pending activity.'],
}

function categoryMonths(categoryId: number, planned: number, currentActual: number, decemberPlanned = planned) {
  return months.map((label, index) => {
    const actual = label === currentShortMonth ? currentActual : 0
    const monthPlanned = index === 11 ? decemberPlanned : planned
    return {
      period_id: index + 1,
      allocation_id: categoryId * 100 + index + 1,
      planned: monthPlanned,
      actual,
      remaining: monthPlanned - actual,
    }
  })
}

const annualOutlookMonths = months.map((label, index) => ({
  period_id: index + 1,
  label,
  starts_on: `${currentYear}-${String(index + 1).padStart(2, '0')}-01`,
  income: index >= 7 ? 15_000 : 14_200,
  category_plan: index === 11 ? 8_300 : 5_300,
  debt_minimums: 200,
  planned_outflow: index === 11 ? 8_500 : 5_500,
  baseline_surplus: (index >= 7 ? 15_000 : 14_200) - (index === 11 ? 8_500 : 5_500),
  expected_irregular: index === 11 ? 3_000 : 0,
  expected_contributors: index === 11 ? [{ name: 'Holiday travel', amount: 3_000 }] : [],
}))

const budget = {
  framework: 'Expense Stack', intro: 'Annual household plan', monthly_income: 14_200,
  total_monthly_outflow: 5_500, baseline_surplus: 8_700,
  stacks: [
    { label: 'Non-discretionary', color: 'red', amount: 4_000, description: 'Fixed', examples: [] },
    { label: 'Discretionary', color: 'yellow', amount: 450, description: 'Flexible', examples: [] },
    { label: 'Sinking Fund — Expected', color: 'green', amount: 600, description: 'Known future costs', examples: [] },
    { label: 'Sinking Fund — Unexpected', color: 'gold', amount: 250, description: 'Life happens', examples: [] },
  ],
  custom_categories_note: 'Use household language.',
  annual_plan: {
    year: currentYear,
    months: months.map((label, index) => ({ id: index + 1, label, starts_on: `${currentYear}-${String(index + 1).padStart(2, '0')}-01`, ends_on: `${currentYear}-${String(index + 1).padStart(2, '0')}-28`, status: 'open' })),
    rows: [
      { id: 1, name: 'Fixed essentials', stack_key: 'non_discretionary', stack_label: 'Non-discretionary', active: true, months: categoryMonths(1, 4_000, 2_800), planned_total: 48_000, actual_total: 2_800 },
      { id: 2, name: 'Dining out', stack_key: 'discretionary', stack_label: 'Discretionary', active: true, months: categoryMonths(2, 450, 475), planned_total: 5_400, actual_total: 475 },
      { id: 3, name: 'Expected sinking fund', stack_key: 'sinking_expected', stack_label: 'Sinking Fund — Expected', active: true, months: categoryMonths(3, 600, 200, 3_600), planned_total: 10_200, actual_total: 200 },
      { id: 4, name: 'Unexpected sinking fund', stack_key: 'sinking_unexpected', stack_label: 'Sinking Fund — Unexpected', active: true, months: categoryMonths(4, 250, 0), planned_total: 3_000, actual_total: 0 },
    ],
    monthly_income: Object.fromEntries(months.map((_, index) => [index + 1, index >= 7 ? 15_000 : 14_200])),
    monthly_debt_minimums: 200,
    income_sources: [{
      id: 1, label: 'Primary income', source_type: 'job', base_amount: 14_200, base_cadence: 'monthly',
      schedule_entries: [{ id: 1, entry_type: 'recurring_change', label: null, amount: 15_000, cadence: 'monthly', effective_on: `${currentYear}-08-01` }],
    }],
    annual_outlook: {
      typical_monthly_outflow: 5_500,
      months: annualOutlookMonths,
      upcoming_spikes: [{ ...annualOutlookMonths[11], amount_above_typical: 3_000 }],
      next_irregular_month: annualOutlookMonths[11],
    },
    pending_transaction_drafts: [
      { id: 91, occurred_on: `${currentYear}-${String(new Date().getMonth() + 1).padStart(2, '0')}-12`, merchant: 'Dinner with friends', amount: 75, amount_cents: 7_500, status: 'pending', source_type: 'receipt', category_id: 2, category_name: 'Dining out' },
      { id: 92, occurred_on: `${currentYear}-${String(new Date().getMonth() + 1).padStart(2, '0')}-15`, merchant: 'Storm supplies', amount: 40, amount_cents: 4_000, status: 'pending', source_type: 'manual_chat', category_id: 4, category_name: 'Unexpected sinking fund' },
    ], pending_mia_action_drafts: [], recent_transactions: [], archived_categories: [],
  },
}

const wealth = {
  summary: { net_worth: 12_345_678.9, liquid_net_worth: 1_234_567.89, ten_year_surplus_capacity: 98_765_432.1, monthly_surplus_available: 12_345.67 },
  milestones: [{ kind: 'debt_remaining', label: 'Debt payoff', current: 5_400, target: 0, unit: 'dollars', status: 'yellow' }],
  guidance: 'Protect options.',
}
const optionality = {
  scenario: 'Founder transition', question: 'Can I leave my job?', target_runway_months: 6, current_runway_months: 0.5, monthly_gap: 4_795,
  choices: [
    { label: 'Stay the course', fit_label: 'Best fit now', fit_tone: 'green', upside: 'Protects the baseline.', tradeoff: 'The transition takes longer.' },
    { label: 'Hybrid transition', fit_label: 'Build runway first', fit_tone: 'red', upside: 'Keeps stable income.', tradeoff: 'Runway is not ready yet.' },
    { label: 'Leap now', fit_label: 'Not ready yet', fit_tone: 'red', upside: 'Maximum focus.', tradeoff: 'Close the runway gap first.' },
  ],
  levers: [{ label: 'Green runway gap', amount: 51_430 }, { label: 'Annual income protected', amount: 170_400 }],
}
const cfoFilter = { framework: 'CFO Filter', prompt: 'Pressure-test the move.', decisions: [{ item: 'Large planned purchase', amount: 1_234_567.89, recommendation: 'Wait', reason: 'Protect runway first.' }], targets: [], priority_stack: ['Essential bills', 'Expected expenses', 'Runway'] }

const miaBudgetDraft = {
  id: 71, status: 'pending', draft_type: 'budget_edit', year: currentYear,
  title: 'Move more into the unexpected sinking fund',
  summary: 'Mia drafted a planned-budget change for review.', rationale: 'Keep actual spending unchanged.', source_prompt: null,
  created_at: '2026-07-17T00:00:00Z', applied_at: null, canceled_at: null,
  impact: {
    scope: `${currentShortMonth} ${currentYear}`, before_monthly_income: 14_200, after_monthly_income: 14_200,
    before_monthly_outflow: 5_500, after_monthly_outflow: 5_650,
    before_baseline_surplus: 8_700, after_baseline_surplus: 8_550,
  },
  items: [{ id: 711, action_type: 'update_allocation', target_record_type: 'BudgetCategory', target_record_id: 4, label: 'Unexpected sinking fund', description: 'Increase the monthly plan after review.', payload: { changes: [{ month: 8 }] }, before_snapshot: {}, after_snapshot: {} }],
}

const miaHouseholdDraft = {
  id: 72, status: 'pending', draft_type: 'household_setup', year: currentYear,
  title: 'Update an approved household number', summary: 'Mia prepared one household change for your review.',
  rationale: 'These values shape Mia’s coaching and stay unchanged until approved.', source_prompt: 'My emergency fund is now $8,500.',
  created_at: '2026-08-17T00:00:00Z', applied_at: null, canceled_at: null,
  impact: {
    scope: 'Current monthly snapshot', before_monthly_income: 14_200, after_monthly_income: 14_200,
    before_monthly_outflow: 5_500, after_monthly_outflow: 5_500,
    before_baseline_surplus: 8_700, after_baseline_surplus: 8_700,
  },
  items: [{
    id: 721, action_type: 'update_setup_value', target_record_type: 'Household', target_record_id: 77,
    label: 'Emergency fund', description: '$5,000.00 → $8,500.00', payload: { key: 'emergency_fund', value: 8_500 },
    before_snapshot: { key: 'emergency_fund', value: 5_000, display: '$5,000.00' },
    after_snapshot: { key: 'emergency_fund', value: 8_500, display: '$8,500.00' },
  }],
}

const miaIncomeDraft = {
  id: 73, status: 'pending', draft_type: 'income_schedule', year: currentYear,
  title: 'Schedule an income change', summary: `Mia prepared setting Primary income to $15,500 per month beginning October ${currentYear}.`,
  rationale: 'The income timeline changes only after approval.', source_prompt: null,
  created_at: '2026-08-17T00:00:00Z', applied_at: null, canceled_at: null,
  impact: {
    scope: `October ${currentYear}`, before_monthly_income: 15_000, after_monthly_income: 15_500,
    before_monthly_outflow: 5_500, after_monthly_outflow: 5_500,
    before_baseline_surplus: 9_500, after_baseline_surplus: 10_000,
  },
  items: [{
    id: 731, action_type: 'upsert_income_schedule_entry', target_record_type: 'IncomeSource', target_record_id: 1,
    label: 'Set Primary income to $15,500.00 per month', description: `Beginning October ${currentYear}: $15,000.00 → $15,500.00 per month.`,
    payload: { income_source_id: 1, entry_type: 'recurring_change', amount_cents: 1_550_000, effective_on: `${currentYear}-10-01` },
    before_snapshot: { effective_monthly_cents: 1_500_000 }, after_snapshot: { effective_monthly_cents: 1_550_000 },
  }],
}

function realWorkspaceData(setupComplete = false) {
  return {
    workspace: {
      mode: 'real', household_id: 77, setup_complete: setupComplete,
      setup_values: {
        household_name: 'Test Participant Household', primary_goal: 'Build a calm monthly plan.',
        primary_income: setupComplete ? 5_000 : 0, business_income: 0, fixed_expenses: setupComplete ? 2_500 : 0,
        flexible_spend: setupComplete ? 600 : 0, expected_sinking_fund: 0, unexpected_sinking_fund: 0,
        emergency_fund: 0, other_assets: 0, credit_card_debt: 0, debt_payment: 0, target_runway_months: 6,
      },
    },
    profile: { ...profile, completeness: setupComplete ? 86 : 29 },
    dashboard,
    budget: { ...budget, annual_plan: { ...budget.annual_plan, pending_mia_action_drafts: [miaBudgetDraft] } },
    wealth,
    optionality,
    cfoFilter,
    mia: { messages: chatMessages(), oldest_message_id: 1, older_message_count: 0, has_older_messages: false, quick_prompts: ['Can I buy the purse?'], disclaimer: 'Education only.' },
  }
}

const pilotCohort = {
  id: 41, name: 'Household CFO pilot', status: 'active', starts_on: '2026-07-01', ends_on: '2026-08-31', notes: '',
  member_count: 1, participant_count: 1, staff_count: 0, setup_complete_count: 0,
  created_at: '2026-07-01T00:00:00Z', updated_at: '2026-07-01T00:00:00Z',
  created_by: { id: 900, email: 'admin@pilot.test', full_name: 'Pilot Admin' },
}

const pilotAdminUser = {
  id: 901, clerk_id: 'e2e_participant', email: 'participant@pilot.test', first_name: 'Test', last_name: 'Participant', full_name: 'Test Participant',
  role: 'participant', invitation_status: 'accepted', invited_at: '2026-07-01T00:00:00Z', accepted_at: '2026-07-02T00:00:00Z',
  last_sign_in_at: '2026-07-17T00:00:00Z', created_at: '2026-07-01T00:00:00Z',
  is_admin: false, is_coach: false, is_participant: true, is_staff: false,
  invited_by: { id: 900, email: 'admin@pilot.test', full_name: 'Pilot Admin' },
  invite_email: { status: 'sent', provider_message_id: null, error: null, last_attempted_at: '2026-07-01T00:00:00Z', last_sent_at: '2026-07-01T00:00:00Z', last_sent_by: null, delivery_log: [] },
  cohorts: [{ id: 1, role: 'participant', cohort: { id: 41, name: 'Household CFO pilot', status: 'active' } }],
  workspace: { invited: true, signed_in: true, setup_status: 'started', setup_complete: false, has_pending_review_work: true, last_safe_activity_at: '2026-07-17T00:00:00Z' },
}

const pilotFeedbackSummary = {
  id: 72, workflow: 'ask_mia', status: 'submitted', screenshot_attached: true,
  reporter: { id: 901, email: 'participant@pilot.test', full_name: 'Test Participant' },
  created_at: '2026-08-08T02:30:00Z', updated_at: '2026-08-08T02:30:00Z',
}

const pilotFeedbackDetail = {
  ...pilotFeedbackSummary,
  attempted: 'Upload a demo-safe budget spreadsheet in Ask Mia.',
  expected: 'Mia should summarize the spreadsheet and ask what to update.',
  actual: 'The upload stopped with a provider error.',
  screenshot: { filename: 'ask-mia-error.png', content_type: 'image/png', byte_size: 18_432 },
}

const emptyPlaidSummary = {
  all_count: 0, posted_outflow_count: 0, posted_outflow_cents: 0,
  pending_count: 0, pending_cents: 0, inflow_count: 0, inflow_cents: 0,
  needs_review_count: 0, needs_review_cents: 0, confirmed_count: 0,
  confirmed_actual_count: 0, confirmed_cents: 0, excluded_count: 0,
}

function chatMessages(count = 125) {
  return Array.from({ length: count }, (_, index) => ({
    id: index + 1,
    role: index % 2 === 0 ? 'user' : 'assistant',
    author: index % 2 === 0 ? 'You' : 'Mia',
    content: `Message ${index + 1}`,
    attachments: index === count - 1 ? [{
      document_import_id: 42, filename: 'receipt.png', content_type: 'image/png', document_kind: 'receipt', status: 'needs_review',
      source_available: true, preview_url: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    }] : [],
  }))
}

async function mockDemoApi(page: Page) {
  let pilotFeedbackStatus = 'submitted'
  const responses: Record<string, unknown> = {
    '/api/demo/profile': profile,
    '/api/demo/dashboard': dashboard,
    '/api/demo/budget': budget,
    '/api/demo/wealth': wealth,
    '/api/demo/optionality': optionality,
    '/api/demo/cfo-filter': cfoFilter,
    '/api/demo/mia/messages': { messages: chatMessages(), oldest_message_id: 1, older_message_count: 0, has_older_messages: false, quick_prompts: ['Can I buy the purse?', 'Why is my readiness Red?', 'Emergency fund or debt first?', 'Can I leave my job?'], disclaimer: 'Education only.' },
    '/api/v1/workspace': realWorkspaceData(false),
    '/api/v1/spending_report': {
      spending_report: {
        period_label: `${currentMonth} ${currentYear}`,
        start_on: `${currentYear}-${String(new Date().getMonth() + 1).padStart(2, '0')}-01`,
        end_on: `${currentYear}-${String(new Date().getMonth() + 1).padStart(2, '0')}-28`,
        totals: { planned: 0, actual: 0, pending: 0, remaining: 0 },
        categories: [],
        transactions: [],
        pending_drafts: [],
      },
    },
    '/api/v1/document_imports': { document_imports: [] },
    '/api/v1/admin/cohorts': { cohorts: [pilotCohort] },
    '/api/v1/admin/users': { users: [pilotAdminUser] },
  }

  await page.route('http://api.test/**', async (route) => {
    const url = new URL(route.request().url())
    const path = url.pathname
    if (path === '/api/v1/workspace/setup' && route.request().method() === 'PATCH') return route.fulfill({ status: 200, json: realWorkspaceData(true) })
    if (path === '/api/v1/pilot_feedback_reports' && route.request().method() === 'POST') {
      return route.fulfill({ status: 201, json: { feedback_report: { id: 55, workflow: 'setup', screenshot_attached: false, status: 'submitted', created_at: '2026-07-17T00:00:00Z' } } })
    }
    if (path === '/api/v1/admin/pilot_feedback_reports' && route.request().method() === 'GET') {
      const filter = url.searchParams.get('status') ?? 'submitted'
      const visible = filter === 'all' || filter === pilotFeedbackStatus
      return route.fulfill({
        status: 200,
        json: {
          feedback_reports: visible ? [{ ...pilotFeedbackSummary, status: pilotFeedbackStatus }] : [],
          counts: { submitted: pilotFeedbackStatus === 'submitted' ? 1 : 0, reviewed: pilotFeedbackStatus === 'reviewed' ? 1 : 0, resolved: pilotFeedbackStatus === 'resolved' ? 1 : 0 },
        },
      })
    }
    if (path === '/api/v1/admin/pilot_feedback_reports/72' && route.request().method() === 'GET') {
      return route.fulfill({ status: 200, json: { feedback_report: { ...pilotFeedbackDetail, status: pilotFeedbackStatus } } })
    }
    if (path === '/api/v1/admin/pilot_feedback_reports/72' && route.request().method() === 'PATCH') {
      pilotFeedbackStatus = route.request().postDataJSON().feedback_report.status
      return route.fulfill({ status: 200, json: { feedback_report: { ...pilotFeedbackDetail, status: pilotFeedbackStatus } } })
    }
    if (path === '/api/v1/admin/pilot_feedback_reports/72/screenshot_url') {
      return route.fulfill({ status: 200, json: { url: 'https://signed.example/inline', download_url: 'https://signed.example/download', expires_in: 300, filename: 'ask-mia-error.png', content_type: 'image/png' } })
    }
    if (/^\/api\/v1\/transaction_drafts\/\d+\/(confirm|ignore|match|reopen)$/.test(path)) {
      return route.fulfill({ status: 200, json: { workspace: realWorkspaceData(true) } })
    }
    if (/^\/api\/v1\/mia_action_drafts\/\d+\/(apply|cancel)$/.test(path)) {
      return route.fulfill({ status: 200, json: { workspace: realWorkspaceData(true) } })
    }
    const body = responses[path]
    if (!body) return route.fulfill({ status: 404, json: { error: `No fixture for ${path}` } })
    return route.fulfill({ status: 200, json: body })
  })
}

async function mockEmptyPlaidState(page: Page, configured: boolean) {
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  await page.route('http://api.test/api/v1/plaid/items', (route) => route.fulfill({
    status: 200,
    json: { configured, environment: configured ? 'sandbox' : null, consent_policy_version: '2026-08-17', items: [] },
  }))
  await page.route('http://api.test/api/v1/plaid/transactions**', (route) => route.fulfill({
    status: 200,
    json: { transactions: [], pagination: { page: 1, per_page: 100, total: 0, has_more: false }, summary: emptyPlaidSummary },
  }))
}

test.beforeEach(async ({ page }) => {
  await mockDemoApi(page)
  await page.addInitScript((messages) => {
    window.localStorage.setItem('household-cfo:mia-chat:v1:preview', JSON.stringify(messages))
  }, chatMessages(100))
})

test('an initial workspace loading failure offers a real retry and restores the participant app', async ({ page }) => {
  let attempts = 0
  let recoveryAllowed = false
  await page.route('http://api.test/api/v1/workspace', (route) => {
    attempts += 1
    return recoveryAllowed
      ? route.fulfill({ status: 200, json: realWorkspaceData(true) })
      : route.fulfill({ status: 503, json: { error: 'The household workspace is temporarily unavailable.' } })
  })

  await page.goto('/?pilot_e2e_role=participant')
  await expect(page.getByRole('alert')).toContainText('temporarily unavailable')
  recoveryAllowed = true
  await page.getByRole('button', { name: 'Try again' }).click()

  await expect(page.getByRole('heading', { name: 'CFO snapshot' })).toBeVisible()
  expect(attempts).toBeGreaterThan(1)
})

test('participant workflow remains usable when Plaid is not configured', async ({ page }) => {
  await mockEmptyPlaidState(page, false)

  await page.goto('/?pilot_e2e_role=participant')
  await openSection(page, 'My Profile')
  await expect(page.getByText('Bank connection is not part of this pilot yet.')).toBeVisible()
  await expect(page.getByText('Nothing is missing from your setup.', { exact: false })).toBeVisible()
  await expect(page.getByText('server-side Plaid credentials', { exact: false })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Connect a bank', exact: true })).toHaveCount(0)

  await openSection(page, 'Review')
  await expect(page.getByText('Manual activity is ready.')).toBeVisible()
  await expect(page.getByText('Connect an account from My Profile.', { exact: false })).toHaveCount(0)
  await expect(page.getByRole('link', { name: 'Budget', exact: true })).toBeVisible()
})

test('configured Plaid clearly supports a participant with no connections', async ({ page }) => {
  await mockEmptyPlaidState(page, true)

  await page.goto('/?pilot_e2e_role=participant')
  await openSection(page, 'My Profile')
  await expect(page.getByText('No bank is connected yet.')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Connect a bank', exact: true })).toBeDisabled()
  await expect(page.getByRole('checkbox', { name: /I authorize Household CFO Method/ })).toBeVisible()

  await openSection(page, 'Review')
  await expect(page.getByText('No bank activity yet.')).toBeVisible()
})

test('account selection keeps activity cards and row totals in the same scope', async ({ page }) => {
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  await page.route('http://api.test/api/v1/plaid/items', (route) => route.fulfill({
    status: 200,
    json: {
      configured: true,
      environment: 'sandbox',
      consent_policy_version: '2026-08-17',
      items: [{
        id: 7,
        institution_name: 'Sandbox Bank',
        status: 'active',
        environment: 'sandbox',
        consented_at: '2026-08-17T00:00:00Z',
        last_synced_at: '2026-08-17T01:00:00Z',
        health: { state: 'healthy', label: 'Healthy', message: 'Bank activity is current.', requires_attention: false, last_successful_update_at: '2026-08-17T01:00:00Z', stale_after: '2026-08-18T01:00:00Z' },
        error_message: null,
        disconnected_at: null,
        auto_confirm_trusted_merchants: false,
        accounts: [
          { id: 11, name: 'Checking', official_name: null, mask: '1234', type: 'depository', subtype: 'checking', current_balance_cents: 200_000, available_balance_cents: 190_000, currency: 'USD', active: true },
          { id: 12, name: 'Savings', official_name: null, mask: '4321', type: 'depository', subtype: 'savings', current_balance_cents: 500_000, available_balance_cents: 500_000, currency: 'USD', active: true },
        ],
      }],
    },
  }))
  await page.route('http://api.test/api/v1/plaid/transactions**', (route) => {
    const accountId = new URL(route.request().url()).searchParams.get('account_id')
    const checkingOnly = accountId === '11'
    return route.fulfill({
      status: 200,
      json: {
        transactions: [],
        pagination: { page: 1, per_page: 100, total: checkingOnly ? 1 : 2, has_more: false },
        summary: {
          ...emptyPlaidSummary,
          all_count: checkingOnly ? 1 : 2,
          posted_outflow_count: checkingOnly ? 1 : 2,
          posted_outflow_cents: checkingOnly ? 4_200 : 14_100,
          confirmed_count: checkingOnly ? 1 : 2,
          confirmed_actual_count: checkingOnly ? 1 : 2,
          confirmed_cents: checkingOnly ? 4_200 : 14_100,
        },
      },
    })
  })

  await page.goto('/?pilot_e2e_role=participant')
  await openSection(page, 'Review')
  const summary = page.getByLabel('Bank activity summary')
  await expect(summary.getByText('$141.00')).toHaveCount(2)

  await page.getByLabel('Account').selectOption('11')
  await expect(summary.getByText('$42.00')).toHaveCount(2)
  await expect(page.getByRole('heading', { name: '1 transaction' })).toBeVisible()
})

test('Plaid Link loads once and opens once after explicit consent', async ({ page }) => {

  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  await page.route('http://api.test/api/v1/plaid/items', (route) => route.fulfill({
    status: 200,
    json: { configured: true, environment: 'sandbox', consent_policy_version: '2026-08-17', items: [] },
  }))
  await page.route('http://api.test/api/v1/plaid/transactions**', (route) => route.fulfill({
    status: 200,
    json: { transactions: [], pagination: { page: 1, per_page: 100, total: 0, has_more: false }, summary: emptyPlaidSummary },
  }))
  await page.route('http://api.test/api/v1/plaid/items/link_token', (route) => route.fulfill({
    status: 200,
    json: { link_token: 'link-sandbox-test', consent_policy_version: '2026-08-17' },
  }))
  await page.route('https://cdn.plaid.com/link/v2/stable/link-initialize.js', (route) => route.fulfill({
    status: 200,
    contentType: 'text/javascript',
    body: `
      window.__plaidScriptLoads = (window.__plaidScriptLoads || 0) + 1;
      window.Plaid = {
        create: function (config) {
          window.__plaidConfig = config;
          setTimeout(function () { if (config.onLoad) config.onLoad(); }, 0);
          return {
            open: function () { window.__plaidOpenCount = (window.__plaidOpenCount || 0) + 1; },
            submit: function () {},
            exit: function (_options, callback) { if (callback) callback(); },
            destroy: function () {}
          };
        }
      };
    `,
  }))

  await page.goto('/?pilot_e2e_role=participant')
  await openSection(page, 'My Profile')
  await page.getByRole('checkbox', { name: /I authorize Household CFO Method/ }).check()
  await page.getByRole('button', { name: 'Connect a bank', exact: true }).click()

  await expect.poll(() => page.evaluate(() => (window as Window & { __plaidOpenCount?: number }).__plaidOpenCount ?? 0)).toBe(1)
  expect(await page.evaluate(() => document.querySelectorAll('script[src="https://cdn.plaid.com/link/v2/stable/link-initialize.js"]').length)).toBe(1)
  expect(await page.evaluate(() => (window as Window & { __plaidScriptLoads?: number }).__plaidScriptLoads)).toBe(1)
})

test('initial Plaid sync refreshes the workspace when transaction history is ready', async ({ page }) => {
  let workspaceRequests = 0
  let connected = false
  let overviewRequestsAfterExchange = 0
  const initialItem = {
    id: 17,
    institution_name: 'Sandbox Bank',
    status: 'active',
    environment: 'sandbox',
    consented_at: '2026-08-22T00:00:00Z',
    last_synced_at: null,
    health: { state: 'initializing', label: 'Preparing history', message: 'The first transaction history sync is still being prepared.', requires_attention: false, last_successful_update_at: null, stale_after: '2026-08-23T00:00:00Z' },
    error_message: null,
    disconnected_at: null,
    auto_confirm_trusted_merchants: false,
    accounts: [],
  }
  const completedItem = {
    ...initialItem,
    last_synced_at: '2026-08-22T01:00:00Z',
    health: { ...initialItem.health, state: 'healthy', label: 'Feed current', message: 'Plaid has updated this connection within the expected window.', last_successful_update_at: '2026-08-22T01:00:00Z' },
  }

  await page.route('http://api.test/api/v1/workspace', (route) => {
    workspaceRequests += 1
    return route.fulfill({ status: 200, json: realWorkspaceData(true) })
  })
  await page.route('http://api.test/api/v1/plaid/items', (route) => {
    if (!connected) return route.fulfill({ status: 200, json: { configured: true, environment: 'sandbox', consent_policy_version: '2026-08-17', items: [] } })
    overviewRequestsAfterExchange += 1
    const synced = overviewRequestsAfterExchange >= 2
    return route.fulfill({ status: 200, json: { configured: true, environment: 'sandbox', consent_policy_version: '2026-08-17', items: [synced ? completedItem : initialItem] } })
  })
  await page.route('http://api.test/api/v1/plaid/transactions**', (route) => route.fulfill({
    status: 200,
    json: { transactions: [], pagination: { page: 1, per_page: 100, total: 0, has_more: false }, summary: emptyPlaidSummary },
  }))
  await page.route('http://api.test/api/v1/plaid/items/link_token', (route) => route.fulfill({
    status: 200,
    json: { link_token: 'link-sandbox-test', consent_policy_version: '2026-08-17' },
  }))
  await page.route('http://api.test/api/v1/plaid/items/exchange', (route) => {
    connected = true
    return route.fulfill({
      status: 201,
      json: { item: initialItem, plaid: { configured: true, environment: 'sandbox', consent_policy_version: '2026-08-17', items: [initialItem] } },
    })
  })
  await page.route('https://cdn.plaid.com/link/v2/stable/link-initialize.js', (route) => route.fulfill({
    status: 200,
    contentType: 'text/javascript',
    body: `
      window.Plaid = {
        create: function (config) {
          window.__plaidConfig = config;
          setTimeout(function () { if (config.onLoad) config.onLoad(); }, 0);
          return { open: function () {}, submit: function () {}, exit: function (_options, callback) { if (callback) callback(); }, destroy: function () {} };
        }
      };
    `,
  }))

  await page.goto('/?pilot_e2e_role=participant')
  await openSection(page, 'My Profile')
  await page.getByRole('checkbox', { name: /I authorize Household CFO Method/ }).check()
  await page.getByRole('button', { name: 'Connect a bank', exact: true }).click()
  await expect.poll(() => page.evaluate(() => Boolean((window as Window & { __plaidConfig?: unknown }).__plaidConfig))).toBe(true)
  await page.evaluate(() => {
    const plaidConfig = (window as Window & { __plaidConfig?: { onSuccess: (token: string, metadata: { institution: { institution_id: string; name: string } }) => void } }).__plaidConfig
    plaidConfig?.onSuccess('public-sandbox-test', { institution: { institution_id: 'ins_17', name: 'Sandbox Bank' } })
  })

  await expect(page.getByText('Sync complete. Posted expenses are ready for household review, and Mia can read the updated bank activity now.')).toBeVisible()
  await expect(page.getByText(/Last synced/)).toBeVisible()
  await expect.poll(() => workspaceRequests).toBeGreaterThan(1)
})

test('Home centers review work and keeps Red guidance internally consistent', async ({ page }) => {
  await page.goto('/')
  await expect(page.getByRole('heading', { name: 'CFO snapshot' })).toBeVisible()
  await expect(page.getByText('What needs review?')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Review 2 transactions' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Review 1 Mia change' })).toBeVisible()
  await expect(page.getByText('Month-to-date inside the annual plan')).toBeVisible()
  const monthSummary = page.getByRole('region', { name: `${currentMonth} ${currentYear} plan position` })
  await expect(monthSummary.getByText('Confirmed actual', { exact: true }).locator('..')).toContainText('$3,475.00')
  await expect(monthSummary.getByText('Pending review', { exact: true }).locator('..')).toContainText('$115.00')
  await expect(monthSummary).toContainText('Pilot guardrail: 40% of positive baseline surplus in Yellow or Green—not ordinary budget remaining.')
  await expect(monthSummary).toContainText('$1,710.00 remains after pending review')
  const homeOutflowBreakdown = monthSummary.getByRole('group', { name: 'Monthly money out breakdown' })
  await expect(homeOutflowBreakdown).toContainText('Category plan')
  await expect(homeOutflowBreakdown).toContainText('$5,300.00')
  await expect(homeOutflowBreakdown).toContainText('Debt minimums')
  await expect(homeOutflowBreakdown).toContainText('$200.00')
  await expect(homeOutflowBreakdown).toContainText('Total money out')
  await expect(homeOutflowBreakdown).toContainText('$5,500.00')
  await expect(monthSummary.locator('.budget-progress-pending')).toBeVisible()
  await page.getByText('Explore the plan behind this snapshot').click()
  const pressureRows = await page.locator('.home-financial-visuals .category-pressure-row').allTextContents()
  expect(pressureRows[0]).toContain('Dining out')
  expect(pressureRows[0]).toContain('$100.00 over if approved')
  await expect(page.locator('.home-financial-visuals .cash-flow-month')).toHaveCount(12)
  const januaryChartButton = page.getByRole('button', { name: new RegExp(`Jan ${currentYear}:`) }).first()
  await januaryChartButton.focus()
  const chartDetail = page.locator('.home-financial-visuals .cash-flow-detail-panel')
  await expect(chartDetail).toContainText(`Jan ${currentYear}`)
  await expect(chartDetail).toContainText('$14,200.00')
  await expect(chartDetail).toContainText('$5,500.00')
  await expect(chartDetail).toContainText('$8,700.00 remains after planned outflow.')
  await expect(chartDetail).toContainText('No expected irregular categories are planned this month.')
  const decemberChartButton = page.getByRole('button', { name: new RegExp(`Dec ${currentYear}:`) }).first()
  await decemberChartButton.focus()
  await expect(chartDetail).toContainText(`Dec ${currentYear}`)
  await expect(chartDetail).toContainText('Expected irregular plan included in outflow')
  await expect(chartDetail).toContainText('Holiday travel')
  await expect(chartDetail).toContainText('$3,000.00')
  await expect(page.locator('.home-financial-visuals .cash-flow-month-summary')).toHaveCount(12)
  await expect(page.getByRole('heading', { name: 'Your path from Red to Yellow to Green' })).toBeVisible()
  await expect(page.getByText('$23,215.00')).toBeVisible()
  await expect(page.getByText('$51,430.00')).toBeVisible()
  await expect(page.locator('.status-ribbon strong')).toHaveText('Red — pause and stabilize basics')
  await expect(page.getByText('Safe to spend').locator('..').getByText('$0.00')).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Protect the baseline and build runway.' })).toBeVisible()
  await expect(page.getByText('enough stability to move with intention')).toHaveCount(0)

  await page.getByRole('button', { name: 'Review 2 transactions' }).click()
  await expect(page).toHaveURL(/#Activity$/)
  await expect(page.getByRole('link', { name: 'Review', exact: true })).toHaveAttribute('aria-current', 'page')
  await expect(page.getByRole('heading', { name: 'Review what changed before it becomes household truth.' })).toBeFocused()
})

test('penny-level plans never show a false over-budget warning', async ({ page }) => {
  const pennyRow = {
    ...budget.annual_plan.rows[0],
    name: 'Penny-perfect category',
    months: categoryMonths(1, 0.3, 0.1),
    planned_total: 3.6,
    actual_total: 0.1,
  }
  const pennyBudget = {
    ...budget,
    annual_plan: {
      ...budget.annual_plan,
      rows: [pennyRow],
      monthly_debt_minimums: 0,
      pending_transaction_drafts: [{
        ...budget.annual_plan.pending_transaction_drafts[0],
        amount: 0.2,
        amount_cents: 20,
        category_id: pennyRow.id,
        category_name: pennyRow.name,
      }],
      pending_mia_action_drafts: [],
    },
  }
  await page.route('http://api.test/api/demo/budget', (route) => route.fulfill({ status: 200, json: pennyBudget }))

  await page.goto('/')

  const monthSummary = page.getByRole('region', { name: `${currentMonth} ${currentYear} plan position` })
  await expect(monthSummary).toContainText('$0.00 remains after pending review')
  await expect(monthSummary).not.toContainText('over plan if all pending items are approved')
})

test('large financial values stay on one line and participant screens stay inside the viewport', async ({ page }) => {
  await page.goto('/')
  for (const section of ['Home', 'Review', 'Ask Mia', 'My Profile', 'Budget', 'Wealth', 'CFO Filter', 'Optionality']) {
    if (section !== 'Home') await openSection(page, section)

    const audit = await page.evaluate(() => {
      const selectors = '.metric-card strong, .stack-card strong, .decision-card > strong, .readiness-milestone-card > strong, .outlook-month span, .outlook-month b, .plan-value strong, .month-plan-income strong, .month-plan-decision-row strong, .cash-flow-detail-panel dd, .transaction-draft-impact-row dd, .transaction-draft-impact-title b'
      const values = Array.from(document.querySelectorAll<HTMLElement>(selectors)).filter((element) => element.offsetParent !== null)
      return {
        documentOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
        overflowingElements: Array.from(document.querySelectorAll<HTMLElement>('main *')).filter((element) => element.offsetParent !== null).filter((element) => {
          const rect = element.getBoundingClientRect()
          return rect.right > document.documentElement.clientWidth + 1 || rect.left < -1
        }).slice(0, 12).map((element) => {
          const rect = element.getBoundingClientRect()
          return `${element.tagName.toLowerCase()}.${element.className}: left ${Math.round(rect.left)}, right ${Math.round(rect.right)}, width ${Math.round(rect.width)}`
        }),
        cockpitWidths: ['.budget-screen', '.annual-budget-panel', '.annual-outlook', '.annual-cash-flow-visual', '.annual-cash-flow-scroll'].map((selector) => {
          const element = document.querySelector<HTMLElement>(selector)
          if (!element || element.offsetParent === null) return `${selector}: hidden`
          const rect = element.getBoundingClientRect()
          return `${selector}: left ${Math.round(rect.left)}, right ${Math.round(rect.right)}, width ${Math.round(rect.width)}, client ${element.clientWidth}, scroll ${element.scrollWidth}`
        }),
        clippedBoxes: Array.from(document.querySelectorAll<HTMLElement>('.shell-header, .screen-heading, .screen-grid > article, .screen-grid > section, .status-ribbon, .metric-card, .insight-card, .stack-card, .decision-card, .choice-card')).filter((element) => element.offsetParent !== null).filter((element) => {
          const rect = element.getBoundingClientRect()
          return rect.left < -1 || rect.right > document.documentElement.clientWidth + 1
        }).map((element) => `${element.className}: ${element.textContent?.trim().replace(/\s+/g, ' ').slice(0, 60)}`),
        splitValues: values.filter((element) => {
          const style = getComputedStyle(element)
          const lineHeight = Number.parseFloat(style.lineHeight)
          return style.whiteSpace !== 'nowrap' || element.scrollWidth > element.clientWidth + 1 || (Number.isFinite(lineHeight) && element.clientHeight > lineHeight * 1.45)
        }).map((element) => element.textContent?.trim()),
      }
    })

    expect(audit.documentOverflow, `${section} should not overflow horizontally. Offenders: ${audit.overflowingElements.join(' | ')}. Cockpit: ${audit.cockpitWidths.join(' | ')}`).toBeLessThanOrEqual(1)
    expect(audit.clippedBoxes, `${section} cards should not be hidden outside the viewport`).toEqual([])
    expect(audit.splitValues, `${section} should not split or clip financial values`).toEqual([])
  }
})

test('Ask Mia renders bounded history and lazy attachment previews', async ({ page }) => {
  await page.goto('/')
  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()
  const suggestedQuestion = page.getByRole('button', { name: 'Why is my readiness Red?' })
  if ((page.viewportSize()?.width ?? 0) <= 620) {
    await expect(suggestedQuestion).toBeHidden()
    await page.getByRole('button', { name: 'Prompts', exact: true }).click()
  }
  await expect(suggestedQuestion).toBeVisible()
  if ((page.viewportSize()?.width ?? 0) <= 620) {
    await page.getByRole('button', { name: 'Prompts', exact: true }).click()
  }
  const promptCue = page.getByText('More prompts →')
  if ((page.viewportSize()?.width ?? 0) <= 720) {
    await expect(promptCue).toBeHidden()
  } else {
    await expect(promptCue).toBeVisible()
  }
  await expect(page.locator('.message-row')).toHaveCount(60)
  await expect(page.getByRole('button', { name: 'Load earlier messages (40 remaining)' })).toBeVisible()
  await expect(page.locator('.message-attachment-card img')).toHaveAttribute('loading', 'lazy')
  await expect(page.getByRole('button', { name: 'Review draft' })).toBeVisible()

  const attachmentPreview = page.getByRole('button', { name: 'Preview Receipt screenshot' })
  await attachmentPreview.focus()
  await attachmentPreview.press('Enter')
  const previewDialog = page.getByRole('dialog', { name: 'Receipt screenshot' })
  await expect(previewDialog).toBeVisible()
  await expect(previewDialog.getByRole('button', { name: 'Close', exact: true })).toBeFocused()
  await page.keyboard.press('Tab')
  await expect(previewDialog.getByRole('button', { name: 'Close', exact: true })).toBeFocused()
  await page.keyboard.press('Escape')
  await expect(previewDialog).toBeHidden()
  await expect(attachmentPreview).toBeFocused()

  await page.getByRole('button', { name: 'Review draft' }).click()
  await expect(page.getByText('Profile completeness', { exact: true })).toBeVisible()
  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()

  await page.getByRole('button', { name: 'Load earlier messages (40 remaining)' }).click()
  await expect(page.locator('.message-row')).toHaveCount(100)
  await expect(page.locator('.chat-history-load')).toHaveCount(0)
})

test('Mia preserves accessible financial lists and emphasis instead of flattening the answer', async ({ page }) => {
  await page.addInitScript(() => {
    window.localStorage.setItem('household-cfo:mia-chat:v1:preview', JSON.stringify([{
      id: 9901,
      role: 'assistant',
      author: 'Mia',
      content: '**Approved household plan**\n\nOnly approved numbers are included.\n- Groceries: **$300.25** planned\n- Dining Out: **$80.50** confirmed',
      attachments: [],
    }]))
  })

  await page.goto('/#Ask%20Mia')

  const answer = page.locator('.message.assistant')
  await expect(answer.getByRole('list')).toBeVisible()
  await expect(answer.getByRole('listitem')).toHaveCount(2)
  await expect(answer.locator('p')).toHaveCount(2)
  await expect(answer.locator('p strong')).toHaveText('Approved household plan')
  await expect(answer.locator('li strong')).toHaveText(['$300.25', '$80.50'])
})

test('chat-first Mia reviews household, income, and budget writes without bypassing approval', async ({ page }) => {
  const baseWorkspace = realWorkspaceData(true)
  const workspace = {
    ...baseWorkspace,
    budget: {
      ...baseWorkspace.budget,
      annual_plan: {
        ...baseWorkspace.budget.annual_plan,
        pending_mia_action_drafts: [miaHouseholdDraft, miaIncomeDraft, miaBudgetDraft],
      },
    },
  }
  await page.route('http://api.test/api/v1/workspace', async (route) => route.fulfill({ status: 200, json: workspace }))

  await page.goto('/?pilot_e2e_role=participant#Ask%20Mia')
  await expect(page.getByRole('heading', { name: 'Tell Mia what changed.' })).toBeVisible()

  if ((page.viewportSize()?.width ?? 0) <= 620) {
    await page.getByRole('button', { name: 'Prompts', exact: true }).click()
  }
  await expect(page.getByText('Nothing changes until you tap Apply.')).toBeVisible()
  const example = page.getByRole('button', { name: 'My take-home pay is now $6,200 a month.' })
  await example.click()
  const composer = page.getByRole('textbox', { name: 'Ask Mia', exact: true })
  await expect(composer).toHaveValue('My take-home pay is now $6,200 a month.')
  await expect(composer).toBeFocused()

  const householdCard = page.locator('.mia-action-draft-card').filter({ hasText: 'Update an approved household number' })
  const incomeCard = page.locator('.mia-action-draft-card').filter({ hasText: 'Schedule an income change' })
  const budgetCard = page.locator('.mia-action-draft-card').filter({ hasText: 'Move more into the unexpected sinking fund' })
  await expect(householdCard).toContainText('Household numbers')
  await expect(householdCard).toContainText('$5,000.00 → $8,500.00')
  await expect(incomeCard).toContainText('Income timeline')
  await expect(incomeCard).toContainText(`October ${currentYear}`)
  await expect(budgetCard).toContainText('Budget plan')
  await expect(budgetCard).toContainText('leave actual spending untouched')

  for (const card of [householdCard, incomeCard, budgetCard]) {
    await expect(card.getByRole('button', { name: 'Apply reviewed change' })).toBeEnabled()
    await expect(card.getByRole('button', { name: 'Cancel draft' })).toBeEnabled()
    await expect(card.getByRole('button', { name: 'Open manual controls' })).toBeEnabled()
  }

  await householdCard.getByRole('button', { name: 'Open manual controls' }).click()
  await expect(page).toHaveURL(/#My%20Profile$/)
  await expect(page.getByRole('heading', { name: 'Pilot Household' })).toBeVisible()
})

test('Ask Mia composer grows, caps, scrolls, and shrinks without losing its controls', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=participant#Ask%20Mia')

  const composer = page.getByRole('textbox', { name: 'Ask Mia', exact: true })
  const sendButton = page.getByRole('button', { name: 'Send message to Mia' })
  const attachmentButton = page.getByRole('button', { name: 'Attach receipt, screenshot, statement, or budget file' })
  const voiceButton = page.getByRole('button', { name: 'Record voice note for Mia' })
  const initialHeight = await composer.evaluate((element) => element.getBoundingClientRect().height)

  await composer.fill('Change my budget,\nthen show me the effect.')
  const wrappedMetrics = await composer.evaluate((element) => {
    const styles = getComputedStyle(element)
    return {
      height: element.getBoundingClientRect().height,
      maxHeight: Number.parseFloat(styles.maxHeight),
      overflowY: styles.overflowY,
    }
  })
  expect(wrappedMetrics.height).toBeGreaterThan(initialHeight)
  expect(wrappedMetrics.height).toBeLessThanOrEqual(wrappedMetrics.maxHeight)
  expect(wrappedMetrics.overflowY).toBe('hidden')

  const composerLayout = await page.locator('.mia-chat-shell .ask-row').evaluate((row) => {
    const rectFor = (selector: string) => {
      const element = row.querySelector(selector)
      if (!(element instanceof HTMLElement)) throw new Error(`Missing composer element: ${selector}`)
      const rect = element.getBoundingClientRect()
      return { left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom, width: rect.width }
    }
    return {
      viewportWidth: document.documentElement.clientWidth,
      attach: rectFor('.composer-attach'),
      voice: rectFor('.composer-voice'),
      textarea: rectFor('textarea'),
      send: rectFor('.send-button'),
    }
  })
  for (const element of [composerLayout.attach, composerLayout.voice, composerLayout.textarea, composerLayout.send]) {
    expect(element.left).toBeGreaterThanOrEqual(0)
    expect(element.right).toBeLessThanOrEqual(composerLayout.viewportWidth + 1)
  }
  expect(composerLayout.attach.right).toBeLessThanOrEqual(composerLayout.voice.left)
  expect(composerLayout.voice.right).toBeLessThanOrEqual(composerLayout.textarea.left)
  expect(composerLayout.textarea.right).toBeLessThanOrEqual(composerLayout.send.left)
  expect(Math.abs(composerLayout.attach.bottom - composerLayout.textarea.bottom)).toBeLessThanOrEqual(1)
  expect(Math.abs(composerLayout.voice.bottom - composerLayout.textarea.bottom)).toBeLessThanOrEqual(1)
  expect(Math.abs(composerLayout.send.bottom - composerLayout.textarea.bottom)).toBeLessThanOrEqual(1)

  await composer.fill(Array.from({ length: 30 }, (_, index) => `Line ${index + 1}: review this planned change before applying it.`).join('\n'))
  const cappedMetrics = await composer.evaluate((element) => {
    const styles = getComputedStyle(element)
    return {
      clientHeight: element.clientHeight,
      scrollHeight: element.scrollHeight,
      maxHeight: Number.parseFloat(styles.maxHeight),
      overflowY: styles.overflowY,
    }
  })
  expect(cappedMetrics.clientHeight).toBeLessThanOrEqual(cappedMetrics.maxHeight)
  expect(cappedMetrics.scrollHeight).toBeGreaterThan(cappedMetrics.clientHeight)
  expect(cappedMetrics.overflowY).toBe('auto')
  await expect(sendButton).toBeVisible()
  await expect(attachmentButton).toBeVisible()
  await expect(voiceButton).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)

  await composer.fill('First line')
  await composer.press('Shift+Enter')
  await composer.type('Second line')
  await expect(composer).toHaveValue('First line\nSecond line')

  await composer.fill('')
  const clearedMetrics = await composer.evaluate((element) => ({
    height: element.getBoundingClientRect().height,
    overflowY: getComputedStyle(element).overflowY,
  }))
  expect(clearedMetrics.height).toBeLessThanOrEqual(initialHeight + 1)
  expect(clearedMetrics.overflowY).toBe('hidden')
})

test('Ask Mia preserves one request ID through a network failure and reload so retry cannot duplicate the turn', async ({ page }) => {
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  const requestIds: string[] = []
  let attempt = 0
  await page.route('http://api.test/api/v1/mia/messages', async (route) => {
    if (route.request().method() !== 'POST') return route.fallback()

    attempt += 1
    requestIds.push(route.request().postDataJSON().request_id)
    if (attempt === 1) return route.abort('timedout')

    return route.fulfill({
      status: 201,
      json: {
        user_message: { id: 701, role: 'user', author: 'You', content: 'What should I focus on?', attachments: [] },
        assistant_message: { id: 702, role: 'assistant', author: 'Mia', content: 'Protect the baseline first.', attachments: [] },
        transaction_draft: null,
        mia_action_draft: null,
        budget: null,
        spending_report: null,
      },
    })
  })

  await page.goto('/?pilot_e2e_role=participant#Ask%20Mia')
  const composer = page.getByRole('textbox', { name: 'Ask Mia', exact: true })
  await composer.fill('What should I focus on?')
  await page.getByRole('button', { name: 'Send message to Mia' }).click()
  await expect(composer).toHaveValue('What should I focus on?')

  await page.reload()
  const restoredComposer = page.getByRole('textbox', { name: 'Ask Mia', exact: true })
  await expect(restoredComposer).toHaveValue('What should I focus on?')
  await page.getByRole('button', { name: 'Send message to Mia' }).click()
  await expect(page.getByText('Protect the baseline first.')).toBeVisible()

  expect(requestIds).toHaveLength(2)
  expect(requestIds[0]).toMatch(/^mia-request-/)
  expect(requestIds[1]).toBe(requestIds[0])
})

test('Ask Mia uses a new request ID when the retry targets a different budget month', async ({ page }) => {
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  const requests: Array<{ request_id: string; month: number }> = []
  let attempt = 0
  await page.route('http://api.test/api/v1/mia/messages', async (route) => {
    if (route.request().method() !== 'POST') return route.fallback()

    attempt += 1
    requests.push(route.request().postDataJSON())
    if (attempt === 1) return route.abort('timedout')

    return route.fulfill({
      status: 201,
      json: {
        user_message: { id: 711, role: 'user', author: 'You', content: 'What should I focus on?', attachments: [] },
        assistant_message: { id: 712, role: 'assistant', author: 'Mia', content: 'Use the newly selected month.', attachments: [] },
        transaction_draft: null,
        mia_action_draft: null,
        budget: null,
        spending_report: null,
      },
    })
  })

  await page.goto('/?pilot_e2e_role=participant#Ask%20Mia')
  const composer = page.getByRole('textbox', { name: 'Ask Mia', exact: true })
  await composer.fill('What should I focus on?')
  await page.getByRole('button', { name: 'Send message to Mia' }).click()
  await expect(composer).toHaveValue('What should I focus on?')

  await openSection(page, 'Budget')
  const nextMonthIndex = (new Date().getMonth() + 1) % 12
  await page.getByLabel('Report month').selectOption(String(nextMonthIndex))
  await openSection(page, 'Ask Mia')
  await page.getByRole('button', { name: 'Send message to Mia' }).click()
  await expect(page.getByText('Use the newly selected month.')).toBeVisible()

  expect(requests).toHaveLength(2)
  expect(requests[1].request_id).not.toBe(requests[0].request_id)
  expect(requests[1].month).toBe(nextMonthIndex + 1)
  expect(requests[1].month).not.toBe(requests[0].month)
})

test('Ask Mia restores uploaded attachment context and its exact request ID after reload', async ({ page }) => {
  const emptySourceErrors: string[] = []
  page.on('console', (message) => {
    if (message.type() === 'error' && message.text().includes('empty string ("") was passed to the src attribute')) {
      emptySourceErrors.push(message.text())
    }
  })
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  const message = 'Please review this receipt.'
  const month = new Date().getMonth() + 1
  const requestId = 'mia-request-attachment-reload-1'
  const signature = JSON.stringify({ message, attachmentIds: [501], year: currentYear, month })
  await page.addInitScript(({ storedRequest }) => {
    window.sessionStorage.setItem('household-cfo:mia-chat:v1:user-901:pending-request', JSON.stringify(storedRequest))
  }, {
    storedRequest: {
      id: requestId,
      signature,
      message,
      attachments: [{
        document_import_id: 501,
        filename: 'saved-receipt.jpg',
        content_type: 'image/jpeg',
        document_kind: 'receipt',
        status: 'needs_review',
        source_available: true,
      }],
    },
  })

  let submittedBody: { request_id?: string; document_import_ids?: number[] } = {}
  await page.route('http://api.test/api/v1/mia/messages', async (route) => {
    if (route.request().method() !== 'POST') return route.fallback()

    submittedBody = route.request().postDataJSON()
    return route.fulfill({
      status: 201,
      json: {
        user_message: { id: 721, role: 'user', author: 'You', content: message, attachments: [] },
        assistant_message: { id: 722, role: 'assistant', author: 'Mia', content: 'I kept the uploaded receipt attached.', attachments: [] },
        transaction_draft: null,
        mia_action_draft: null,
        budget: null,
        spending_report: null,
      },
    })
  })

  await page.goto('/?pilot_e2e_role=participant#Ask%20Mia')
  await expect(page.getByRole('textbox', { name: 'Ask Mia', exact: true })).toHaveValue(message)
  await expect(page.getByText('saved-receipt.jpg')).toBeVisible()
  await expect(page.locator('.composer-attachment-card img')).toHaveCount(0)
  await page.getByRole('button', { name: 'Receipt screenshot', exact: true }).click()
  await expect(page.getByText('This restored upload has no local preview. You can still send it to Mia.')).toBeVisible()
  await expect(page.locator('.local-attachment-preview img')).toHaveCount(0)
  expect(emptySourceErrors).toEqual([])
  await page.getByRole('button', { name: 'Close', exact: true }).click()
  await page.getByRole('button', { name: 'Send message to Mia' }).click()
  await expect(page.getByText('I kept the uploaded receipt attached.')).toBeVisible()

  expect(submittedBody.request_id).toBe(requestId)
  expect(submittedBody.document_import_ids).toEqual([501])
})

test('Budget explains scheduled income changes and upcoming annual pressure', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'Money in, money out, and what is left.' })).toBeVisible()
  const outflowBreakdown = page.getByRole('group', { name: 'Monthly money out breakdown' })
  await expect(outflowBreakdown).toContainText('Category plan')
  await expect(outflowBreakdown).toContainText('$5,300.00')
  await expect(outflowBreakdown).toContainText('Debt minimums')
  await expect(outflowBreakdown).toContainText('$200.00')
  await expect(outflowBreakdown).toContainText('Total money out')
  await expect(outflowBreakdown).toContainText('$5,500.00')
  const annualMoneyOut = page.getByLabel('Annual money out breakdown')
  await expect(annualMoneyOut).toContainText('Annual category plan$66,600.00')
  await expect(annualMoneyOut).toContainText('Annual debt minimums$2,400.00')
  await expect(annualMoneyOut).toContainText('Total annual money out$69,000.00')
  await expect(page.getByRole('button', { name: 'Ask Mia to update my plan' })).toBeVisible()
  await expect(page.getByRole('region', { name: 'Annual budget table' })).toHaveCount(0)
  await expect(page.getByRole('heading', { name: 'Set it once, then schedule what changes.' })).toHaveCount(0)
  await expect(page.getByRole('heading', { name: 'Every category, ordered by pressure' })).toHaveCount(0)

  await page.getByRole('button', { name: 'Manage manually' }).click()
  const manualManager = page.locator('.budget-manual-manager')
  await expect(manualManager).toBeInViewport()
  await expect(page.getByLabel('New category')).toBeFocused()
  await page.getByRole('button', { name: 'Schedule income' }).click()
  await expect(page.getByRole('heading', { name: 'Set it once, then schedule what changes.' })).toBeVisible()
  await expect(page.getByText('Recurring amount changes')).toBeVisible()
  await expect(page.getByText('$15,000.00 Monthly')).toBeVisible()
  await page.getByRole('button', { name: 'Close manual tools' }).click()

  await expect(page.getByRole('heading', { name: 'See the expensive months before they arrive.' })).toBeVisible()
  await expect(page.getByText('Dec spending spike')).toBeVisible()
  await expect(page.getByText('Holiday travel')).toBeVisible()
  await expect(page.getByRole('heading', { name: 'See which layer is using the plan.' })).toBeVisible()
  await expect(page.locator('.expense-stack-row')).toHaveCount(4)
  await expect(page.getByText('$75.00 pending review—not included in actuals.')).toBeVisible()
  await page.getByText('Monthly activity and transactions').click()
  await expect(page.getByRole('heading', { name: 'Every category, ordered by pressure' })).toBeVisible()
  await expect(page.locator('.annual-outlook .cash-flow-month')).toHaveCount(12)
  const diningDraft = page.locator('.transaction-draft-card').filter({ hasText: 'Dinner with friends' })
  await expect(diningDraft.getByRole('region', { name: new RegExp(`Budget impact if approved for ${currentShortMonth}`) })).toContainText('$100.00 over plan if approved.')
  await expect(diningDraft).toContainText('Actuals stay unchanged until you confirm.')
})

test('continuing job income is never assumed and requires explicit participant approval', async ({ page }) => {
  const submittedChanges: Array<{ retained_after_transition?: boolean }> = []
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  await page.route('http://api.test/api/v1/income_schedule_entries**', (route) => {
    const submitted = route.request().postDataJSON().income_schedule_entry as { retained_after_transition?: boolean; amount: string; effective_on: string }
    submittedChanges.push(submitted)
    const updatedBudget = structuredClone(realWorkspaceData(true).budget)
    updatedBudget.annual_plan.income_sources[0].schedule_entries = [{
      id: 27,
      entry_type: 'recurring_change',
      label: null,
      amount: Number(submitted.amount),
      cadence: 'monthly',
      effective_on: submitted.effective_on,
      retained_after_transition: submitted.retained_after_transition === true,
    }]
    return route.fulfill({ status: route.request().method() === 'POST' ? 201 : 200, json: { budget: updatedBudget } })
  })

  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  await page.getByRole('button', { name: 'Manage manually' }).click()
  await page.getByRole('button', { name: 'Schedule income' }).click()
  await page.getByRole('spinbutton', { name: 'Amount' }).fill('7500')

  const retention = page.getByRole('checkbox', { name: /This job income will continue after my transition/ })
  await expect(retention).not.toBeChecked()
  await retention.check()
  await page.getByRole('button', { name: 'Schedule income change' }).click()
  await expect(page.getByText('Confirmed to continue after transition')).toBeVisible()
  expect(submittedChanges[0].retained_after_transition).toBe(true)

  await page.locator('.annual-income-planner').getByRole('button', { name: 'Edit', exact: true }).click()
  await expect(retention).toBeChecked()
  await retention.uncheck()
  await page.getByRole('button', { name: 'Save income change' }).click()
  await expect(page.getByText('Confirmed to continue after transition')).toBeHidden()
  expect(submittedChanges[1].retained_after_transition).toBe(false)
})

test('Budget keeps headline, cockpit, and chart on the selected report month', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('link', { name: 'Budget', exact: true }).click()

  const reportMonth = page.getByLabel('Report month')
  const headline = page.locator('.budget-period-summary')
  const cockpit = page.locator('.month-plan-summary')
  const chartDetail = page.locator('.annual-outlook .cash-flow-detail-panel')

  await reportMonth.selectOption('11')
  await expect(headline.getByRole('heading', { name: `Dec ${currentYear}` })).toBeVisible()
  await expect(headline).toContainText('Income$15,000.00')
  await expect(headline).toContainText('Planned outflow$8,500.00')
  await expect(headline).toContainText('Baseline surplus$6,500.00')
  await expect(cockpit).toContainText(`Dec ${currentYear}`)
  await expect(cockpit.getByRole('group', { name: 'Monthly money out breakdown' })).toContainText('Total money out$8,500.00')
  await expect(chartDetail).toContainText(`Report monthDec ${currentYear}`)
  await expect(chartDetail).toContainText('Planned outflow$8,500.00')

  await page.locator('.annual-outlook .cash-flow-month-trigger').first().click()
  await expect(chartDetail).toContainText(`Chart previewJan ${currentYear}`)
  await expect(reportMonth).toHaveValue('11')

  await page.getByRole('button', { name: 'This month', exact: true }).click()
  await expect(reportMonth).toHaveValue(String(new Date().getMonth()))
  await expect(headline.getByRole('heading', { name: `${currentShortMonth} ${currentYear}` })).toBeVisible()
  await expect(chartDetail).toContainText(`Report month${currentShortMonth} ${currentYear}`)
})

test('focused manual budget tools expose exact controls without a page hunt and protect dirty edits', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  await page.getByRole('button', { name: 'Manage manually' }).click()

  const manager = page.locator('.budget-manual-manager')
  await expect(manager).toBeInViewport()
  await expect(page.getByLabel('New category')).toBeFocused()
  await expect(page.getByRole('region', { name: 'Annual budget table' })).toHaveCount(0)

  await page.getByRole('button', { name: 'Edit monthly plan' }).click()
  const table = page.getByRole('region', { name: 'Annual budget table' })
  await expect(table).toBeVisible()
  const januaryDining = page.getByLabel('Dining out planned for Jan')
  await januaryDining.fill('650')
  await expect(manager).toContainText('1 unsaved change. Save or cancel before switching tools.')
  await page.getByRole('button', { name: 'Edit monthly plan' }).click()
  await expect(januaryDining).toHaveValue('650')
  await expect(page.getByRole('button', { name: 'Add a category' })).toBeDisabled()
  await expect(page.getByRole('button', { name: 'Schedule income' })).toBeDisabled()
  await expect(page.getByRole('button', { name: 'Close manual tools' })).toBeDisabled()
  await expect(page.getByRole('button', { name: 'Previous year' })).toBeDisabled()
  await expect(page.getByRole('button', { name: 'Next year' })).toBeDisabled()
  await expect(page.getByLabel('Report month')).toBeDisabled()
  await page.getByRole('link', { name: 'Home', exact: true }).click()
  await expect(manager.getByRole('alert')).toContainText('Save or cancel them before leaving Budget')
  await expect(januaryDining).toHaveValue('650')
  await expect(page.getByRole('heading', { name: 'Money in, money out, and what is left.' })).toBeVisible()
  await page.goBack()
  await expect(page).toHaveURL(/#Budget$/)
  await expect(manager.getByRole('alert')).toContainText('Save or cancel them before leaving Budget')
  await expect(januaryDining).toHaveValue('650')
  await page.getByRole('button', { name: 'Cancel', exact: true }).click()
  await expect(manager).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Manage manually' })).toBeFocused()

  await page.getByRole('button', { name: 'Ask Mia to update my plan' }).click()
  const composer = page.getByRole('textbox', { name: 'Ask Mia' })
  await expect(composer).toBeFocused()
  await expect(composer).toHaveValue('I want to update my budget. Help me make this change safely: ')
})

test('a partially saved budget keeps the approved change and protects unapplied drafts until retry', async ({ page }) => {
  const savedAmounts = new Map<number, number>()
  let rejectFebruaryOnce = true

  await page.route('http://api.test/api/v1/budget_allocations/*', (route) => {
    const allocationId = Number(new URL(route.request().url()).pathname.split('/').at(-1))
    if (allocationId === 202 && rejectFebruaryOnce) {
      rejectFebruaryOnce = false
      return route.fulfill({ status: 503, json: { error: 'February could not be saved.' } })
    }

    savedAmounts.set(allocationId, Number(route.request().postDataJSON().allocation.planned_amount))
    const updatedBudget = structuredClone(realWorkspaceData(true).budget)
    updatedBudget.annual_plan.rows = updatedBudget.annual_plan.rows.map((row) => ({
      ...row,
      months: row.months.map((month) => ({
        ...month,
        planned: savedAmounts.get(month.allocation_id) ?? month.planned,
      })),
    }))
    return route.fulfill({ status: 200, json: { budget: updatedBudget } })
  })

  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  await page.getByRole('button', { name: 'Manage manually' }).click()
  await page.getByRole('button', { name: 'Edit monthly plan' }).click()

  const manager = page.locator('.budget-manual-manager')
  const januaryDining = page.getByLabel('Dining out planned for Jan')
  const februaryDining = page.getByLabel('Dining out planned for Feb')
  await januaryDining.fill('650')
  await februaryDining.fill('700')
  await page.getByRole('button', { name: 'Save 2 changes' }).click()

  await expect(manager.getByRole('alert')).toContainText('Earlier changes were saved; your remaining edits are still available to retry.')
  await expect(januaryDining).toHaveValue('650')
  await expect(februaryDining).toHaveValue('700')
  await expect(manager).toContainText('1 unsaved change. Save or cancel before switching tools.')
  await expect(page.getByLabel('Report month')).toBeDisabled()
  await page.getByRole('link', { name: 'Home', exact: true }).click()
  await expect(manager.getByRole('alert')).toContainText('Save or cancel them before leaving Budget')
  await expect(februaryDining).toHaveValue('700')

  await page.getByRole('button', { name: 'Save 1 change' }).click()
  await expect(manager).toHaveCount(0)
  expect(savedAmounts.get(201)).toBe(650)
  expect(savedAmounts.get(202)).toBe(700)
})

test('participant navigation remains available after deep scrolling', async ({ page }) => {
  await page.goto('/')
  const homeHeaderHeight = await page.locator('.shell-header').evaluate((element) => Math.round(element.getBoundingClientRect().height))
  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  const budgetHeaderHeight = await page.locator('.shell-header').evaluate((element) => Math.round(element.getBoundingClientRect().height))
  expect(budgetHeaderHeight).toBe(homeHeaderHeight)
  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight))
  await expect(page.locator('.tabs-shell')).toBeInViewport()
  const top = await page.locator('.tabs-shell').evaluate((element) => Math.round(element.getBoundingClientRect().top))
  expect(top).toBe(0)
  await page.getByRole('link', { name: 'Home', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'CFO snapshot' })).toBeVisible()
  await expect.poll(() => page.evaluate(() => Math.round(window.scrollY))).toBe(0)
  await expect(page.locator('.shell-header')).toHaveCount(1)
})

test('participant links preserve browser history, heading focus, and section scroll', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name.includes('mobile'), 'desktop history and focus assertion')
  await page.goto('/#Home')

  const budgetLink = page.getByRole('link', { name: 'Budget', exact: true })
  await expect(budgetLink).toHaveAttribute('href', '#Budget')
  await budgetLink.click()
  await expect(page).toHaveURL(/#Budget$/)
  const budgetHeading = page.getByRole('heading', { name: 'Know what came in, what went out, and what is left.' })
  await expect(budgetHeading).toBeFocused()

  await page.evaluate(() => window.scrollTo(0, Math.min(900, document.documentElement.scrollHeight - window.innerHeight)))
  const budgetScrollTop = await page.evaluate(() => Math.round(window.scrollY))
  expect(budgetScrollTop).toBeGreaterThan(0)

  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()
  await expect(page).toHaveURL(/#Ask%20Mia$/)
  await expect(page.getByRole('heading', { name: 'Tell Mia what changed.' })).toBeFocused()
  await expect.poll(() => page.evaluate(() => Math.round(window.scrollY))).toBe(0)

  await page.goBack()
  await expect(page).toHaveURL(/#Budget$/)
  await expect(budgetHeading).toBeFocused()
  await expect.poll(() => page.evaluate(() => Math.round(window.scrollY))).toBe(budgetScrollTop)

  await page.goBack()
  await expect(page).toHaveURL(/#Home$/)
  await expect(page.getByRole('heading', { name: 'CFO snapshot' })).toBeFocused()

  await page.goForward()
  await expect(page).toHaveURL(/#Budget$/)
  await expect(budgetHeading).toBeFocused()
})

test('unfinished Plaid returns keep Profile and the URL aligned through reload and history', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name.includes('mobile'), 'desktop history assertion')
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  await page.route('https://cdn.plaid.com/link/v2/stable/link-initialize.js', (route) => route.fulfill({
    status: 200,
    contentType: 'text/javascript',
    body: `
      window.Plaid = {
        create: function (config) {
          setTimeout(function () { if (config.onLoad) config.onLoad(); }, 0);
          return { open: function () {}, submit: function () {}, exit: function (_options, callback) { if (callback) callback(); }, destroy: function () {} };
        }
      };
    `,
  }))
  await page.addInitScript(() => {
    window.localStorage.setItem('household-cfo:plaid-oauth:v1', JSON.stringify({
      userId: '901',
      linkToken: 'link-oauth-regression',
      updateItemId: null,
      createdAt: Date.now(),
    }))
  })

  await page.goto('/#Home')
  await page.goto('/?pilot_e2e_role=participant&oauth_state_id=unfinished#Budget')
  await expect(page).toHaveURL(/oauth_state_id=unfinished#My%20Profile$/)
  await expect(page.getByRole('heading', { name: 'Pilot Household' })).toBeVisible()

  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  await expect(page).toHaveURL(/oauth_state_id=unfinished#My%20Profile$/)
  await expect(page.getByRole('heading', { name: 'Pilot Household' })).toBeVisible()

  await page.reload()
  await expect(page).toHaveURL(/oauth_state_id=unfinished#My%20Profile$/)
  await expect(page.getByRole('heading', { name: 'Pilot Household' })).toBeVisible()

  await page.goBack()
  await expect(page).toHaveURL(/#Home$/)
  await page.goForward()
  await expect(page).toHaveURL(/oauth_state_id=unfinished#My%20Profile$/)
  await expect(page.getByRole('heading', { name: 'Pilot Household' })).toBeVisible()
})

test('query-only Plaid returns preserve callback state while the workspace loads', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name.includes('mobile'), 'desktop callback loading assertion')
  let releaseWorkspace!: () => void
  const workspaceReady = new Promise<void>((resolve) => { releaseWorkspace = resolve })
  await page.route('http://api.test/api/v1/workspace', async (route) => {
    await workspaceReady
    await route.fulfill({ status: 200, json: realWorkspaceData(true) })
  })
  await page.route('https://cdn.plaid.com/link/v2/stable/link-initialize.js', (route) => route.fulfill({
    status: 200,
    contentType: 'text/javascript',
    body: `
      window.Plaid = {
        create: function (config) {
          setTimeout(function () { if (config.onLoad) config.onLoad(); }, 0);
          return { open: function () {}, submit: function () {}, exit: function (_options, callback) { if (callback) callback(); }, destroy: function () {} };
        }
      };
    `,
  }))
  await page.addInitScript(() => {
    window.localStorage.setItem('household-cfo:plaid-oauth:v1', JSON.stringify({
      userId: '901',
      linkToken: 'link-oauth-delayed-workspace',
      updateItemId: null,
      createdAt: Date.now(),
    }))
  })

  await page.goto('/?pilot_e2e_role=participant&oauth_state_id=delayed')
  await expect(page).toHaveURL(/oauth_state_id=delayed#My%20Profile$/)
  await expect(page.getByRole('heading', { name: 'Loading your first cohort workspace.' })).toBeVisible()

  releaseWorkspace()
  await expect(page).toHaveURL(/oauth_state_id=delayed#My%20Profile$/)
  await expect(page.getByRole('heading', { name: 'Pilot Household' })).toBeVisible()
})

test('stale Plaid return queries recover normal participant navigation', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name.includes('mobile'), 'desktop callback recovery assertion')
  await page.goto('/?pilot_e2e_role=participant&oauth_state_id=stale#Budget')

  await expect(page).toHaveURL(/\?pilot_e2e_role=participant#My%20Profile$/)
  await expect(page.getByRole('heading', { name: 'Give Mia the basics for a useful first answer.' })).toBeVisible()

  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  await expect(page).toHaveURL(/\?pilot_e2e_role=participant#Budget$/)
  await expect(page.getByRole('heading', { name: 'Know what came in, what went out, and what is left.' })).toBeFocused()

  await page.reload()
  await expect(page).toHaveURL(/\?pilot_e2e_role=participant#Budget$/)
  await expect(page.getByRole('heading', { name: 'Know what came in, what went out, and what is left.' })).toBeVisible()
})

test('participant history canonicalizes unauthorized Admin routes to Home', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name.includes('mobile'), 'desktop authorization history assertion')
  await page.goto('/?pilot_e2e_role=participant#Budget')
  await expect(page.getByRole('heading', { name: 'Know what came in, what went out, and what is left.' })).toBeVisible()

  await page.goto('/?pilot_e2e_role=participant#Admin')
  await expect(page).toHaveURL(/\?pilot_e2e_role=participant#Home$/)
  await expect(page.getByRole('heading', { name: 'CFO snapshot' })).toBeVisible()

  await page.goBack()
  await expect(page).toHaveURL(/\?pilot_e2e_role=participant#Budget$/)
  await expect(page.getByRole('heading', { name: 'Know what came in, what went out, and what is left.' })).toBeFocused()

  await page.goForward()
  await expect(page).toHaveURL(/\?pilot_e2e_role=participant#Home$/)
  await expect(page.getByRole('heading', { name: 'CFO snapshot' })).toBeFocused()
})

test('Clerk-enabled route recovery waits for participant authorization before canonicalizing', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name.includes('mobile'), 'desktop authorization loading assertion')
  await page.goto('/?pilot_e2e_role=delayed_participant#Admin')

  await expect(page).toHaveURL(/#Admin$/)
  await expect(page).toHaveURL(/#Home$/)
  await expect(page.getByRole('heading', { name: 'CFO snapshot' })).toBeVisible()

  await page.goto('/?pilot_e2e_role=delayed_participant#Not%20A%20Screen')
  await expect(page).toHaveURL(/#Home$/)
})

test('Wealth and Optionality explain decisions without fake payoff progress or conflicting scores', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Wealth')
  const debtCard = page.getByRole('heading', { name: 'Debt payoff' }).locator('..')
  await expect(debtCard.getByText('$5,400.00 remaining')).toBeVisible()
  await expect(debtCard.locator('.progress-track')).toHaveCount(0)
  await expect(debtCard).not.toContainText('0 / 5,400')
  const outlook = page.locator('.metric-card').filter({ hasText: '10-year surplus capacity' })
  await expect(outlook).toContainText('planning capacity—not confirmed savings, an investment contribution, or a forecast')
  await expect(page.getByText('Retirement projection', { exact: true })).toHaveCount(0)

  await openSection(page, 'Optionality')
  await expect(page.getByText('Best fit now')).toBeVisible()
  await expect(page.getByText('Build runway first')).toBeVisible()
  await expect(page.getByText('Not ready yet', { exact: true })).toBeVisible()
  await expect(page.getByText(/\/100 readiness/)).toHaveCount(0)
})

test('Wealth stays accurate while the frontend and API metric contracts roll out', async ({ page }) => {
  await page.route('http://api.test/api/demo/wealth', (route) => route.fulfill({
    status: 200,
    json: {
      ...wealth,
      summary: {
        net_worth: 142_800,
        liquid_net_worth: 17_740,
        retirement_projection: 190_000,
        monthly_wealth_building: 655,
      },
    },
  }))

  await page.goto('/')
  await openSection(page, 'Wealth')

  await expect(page.locator('.metric-card').filter({ hasText: '10-year surplus capacity' })).toContainText('$78,600.00')
  await expect(page.locator('.metric-card').filter({ hasText: 'Monthly surplus available' })).toContainText('$655.00')
  await expect(page.getByText('$190,000.00', { exact: true })).toHaveCount(0)
})

test('desktop Tools stays anchored to its trigger and contains keyboard focus', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name.includes('mobile'), 'desktop-only popover assertion')
  await page.goto('/')

  const tools = page.getByRole('button', { name: 'Tools', exact: true })
  const triggerBox = await tools.boundingBox()
  await tools.click()

  const dialog = page.getByRole('dialog', { name: 'Go deeper when you need to.' })
  await expect(dialog).toBeVisible()
  await dialog.evaluate(async (element) => {
    await Promise.all(element.getAnimations().map((animation) => animation.finished.catch(() => undefined)))
  })
  const dialogBox = await dialog.boundingBox()
  expect(triggerBox).not.toBeNull()
  expect(dialogBox).not.toBeNull()
  expect(dialogBox?.y ?? 0).toBeGreaterThanOrEqual((triggerBox?.y ?? 0) + (triggerBox?.height ?? 0) + 6)
  expect((dialogBox?.y ?? 0) + (dialogBox?.height ?? 0)).toBeLessThanOrEqual(page.viewportSize()?.height ?? 720)

  await expect(page.getByRole('link', { name: 'My Profile', exact: true })).toBeFocused()
  await page.keyboard.press('Shift+Tab')
  await expect(dialog.getByRole('button', { name: 'Close tools' })).toBeFocused()
  await page.keyboard.press('Shift+Tab')
  await expect(page.getByRole('link', { name: 'Optionality', exact: true })).toBeFocused()
  await page.keyboard.press('Tab')
  await expect(dialog.getByRole('button', { name: 'Close tools' })).toBeFocused()
  await page.keyboard.press('Escape')
  await expect(dialog).toBeHidden()
  await expect(tools).toBeFocused()

  await tools.click()
  await openSection(page, 'My Profile')
  await expect(page.getByRole('heading', { name: 'Pilot Household' })).toBeFocused()
})

test('compact phone layouts keep a stable shell and overlay secondary tools without page reflow', async ({ page }, testInfo) => {
  test.skip(!testInfo.project.name.includes('mobile'), 'mobile-only responsive assertion')
  await page.goto('/')

  const header = page.locator('.shell-header')
  const homeHeaderBox = await header.boundingBox()
  const homeContentY = await page.locator('.home-welcome-panel').evaluate((element) => Math.round(element.getBoundingClientRect().top))
  const tools = page.getByRole('button', { name: 'Tools', exact: true })
  await expect(tools).toBeVisible()
  await expect(page.getByRole('link', { name: 'Review', exact: true })).toBeVisible()
  await expect(tools).toHaveAttribute('aria-expanded', 'false')
  await expect(page.getByRole('link', { name: 'My Profile', exact: true })).toHaveCount(0)
  await tools.click()
  await expect(tools).toHaveAttribute('aria-expanded', 'true')
  await expect(page.getByRole('link', { name: 'My Profile', exact: true })).toBeVisible()
  expect(await page.locator('.home-welcome-panel').evaluate((element) => Math.round(element.getBoundingClientRect().top))).toBe(homeContentY)
  await expect(page.locator('.tabs-secondary')).toHaveCSS('position', 'fixed')
  const primaryNavButtons = page.locator('.tabs > :is(a, button)')
  const touchHeights = await primaryNavButtons.evaluateAll((buttons) => buttons.map((button) => button.getBoundingClientRect().height))
  expect(Math.min(...touchHeights)).toBeGreaterThanOrEqual(44)
  await openSection(page, 'My Profile')
  await expect(tools).toHaveAttribute('aria-expanded', 'false')
  await expect(page.getByRole('heading', { name: 'Pilot Household' })).toBeFocused()
  await page.getByRole('link', { name: 'Home', exact: true }).click()
  await page.getByText('Explore the plan behind this snapshot').click()
  await expect(page.locator('.home-financial-visuals .cash-flow-month')).toHaveCount(12)
  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()
  await expect.poll(() => page.evaluate(() => Math.round(window.scrollY))).toBe(0)
  const askMiaHeaderBox = await header.boundingBox()
  expect(Math.abs((askMiaHeaderBox?.height ?? 0) - (homeHeaderBox?.height ?? 0))).toBeLessThan(0.5)
  expect(Math.abs((askMiaHeaderBox?.y ?? 0) - (homeHeaderBox?.y ?? 0))).toBeLessThan(0.5)
  await expect(page.getByText('More prompts →')).toBeHidden()
  await page.locator('.screen-grid').evaluate(async (screen) => {
    await Promise.all(screen.getAnimations().map((animation) => animation.finished.catch(() => undefined)))
  })
  const chatLayout = await page.locator('.mia-chat-shell').evaluate((shell) => {
    const shellBox = shell.getBoundingClientRect()
    const conversationBox = shell.querySelector('.chat-card-wrap')?.getBoundingClientRect()
    const composerBox = shell.querySelector('.ask-row')?.getBoundingClientRect()
    return {
      shell: { x: shellBox.x, y: shellBox.y, width: shellBox.width, height: shellBox.height, bottom: shellBox.bottom },
      conversationHeight: conversationBox?.height ?? 0,
      composerBottom: composerBox?.bottom ?? Number.POSITIVE_INFINITY,
    }
  })
  const promptButtons = page.locator('.chat-prompts button')
  const promptWidths = await promptButtons.evaluateAll((buttons) => buttons.map((button) => button.getBoundingClientRect().width))
  expect(Math.max(...promptWidths)).toBeLessThanOrEqual(chatLayout.shell.width - 20)
  const contextBox = await page.locator('.mia-context').boundingBox()
  expect(chatLayout.conversationHeight).toBeGreaterThan(100)
  expect(chatLayout.composerBottom).toBeLessThanOrEqual(chatLayout.shell.bottom + 1)
  expect(contextBox).not.toBeNull()
  expect(chatLayout.shell.y).toBeLessThan(contextBox?.y ?? 0)
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})

test('mobile Ask Mia prioritizes conversation and keeps full-screen chat above its backdrop', async ({ page }, testInfo) => {
  test.skip(!testInfo.project.name.includes('mobile'), 'mobile-only chat assertion')
  await page.goto('/#Ask%20Mia')
  await expect(page.getByRole('heading', { name: 'Ask Mia', exact: true })).toBeVisible()

  const suggestionsButton = page.getByRole('button', { name: 'Prompts', exact: true })
  const suggestedQuestion = page.getByRole('button', { name: 'Why is my readiness Red?' })
  await expect(suggestionsButton).toHaveAttribute('aria-expanded', 'false')
  await expect(suggestedQuestion).toBeHidden()

  const compactLayout = await page.locator('.mia-chat-shell').evaluate((shell) => {
    const history = shell.querySelector('.chat-card-wrap')?.getBoundingClientRect()
    const shellBox = shell.getBoundingClientRect()
    return {
      historyHeight: history?.height ?? 0,
      shellHeight: shellBox.height,
    }
  })
  expect(compactLayout.historyHeight).toBeGreaterThan(compactLayout.shellHeight * 0.6)

  await suggestionsButton.focus()
  await suggestionsButton.press('Enter')
  await expect(suggestionsButton).toHaveAttribute('aria-expanded', 'true')
  await expect(suggestedQuestion).toBeVisible()
  const historyWhileOpen = await page.locator('.chat-card-wrap').evaluate((history) => history.getBoundingClientRect().height)
  expect(historyWhileOpen).toBeCloseTo(compactLayout.historyHeight, 0)

  await page.keyboard.press('Escape')
  await expect(suggestionsButton).toHaveAttribute('aria-expanded', 'false')
  await expect(suggestionsButton).toBeFocused()
  await suggestionsButton.click()

  await page.getByRole('button', { name: 'My take-home pay is now $6,200 a month.' }).click()
  await expect(suggestionsButton).toHaveAttribute('aria-expanded', 'false')
  await expect(page.getByRole('textbox', { name: 'Ask Mia', exact: true })).toHaveValue('My take-home pay is now $6,200 a month.')
  await expect(page.getByRole('textbox', { name: 'Ask Mia', exact: true })).toBeFocused()

  const expandButton = page.getByRole('button', { name: 'Expand Ask Mia chat' })
  await expandButton.focus()
  await expandButton.press('Enter')
  await expect(page.getByRole('dialog', { name: 'Ask Mia' })).toBeVisible()
  const expandedLayout = await page.locator('.mia-chat-shell').evaluate((shell) => {
    const box = shell.getBoundingClientRect()
    const topElement = document.elementFromPoint(window.innerWidth / 2, window.innerHeight / 2)
    return {
      x: box.x,
      y: box.y,
      width: box.width,
      height: box.height,
      viewportWidth: window.innerWidth,
      viewportHeight: window.innerHeight,
      shellOwnsViewportCenter: Boolean(topElement && shell.contains(topElement)),
      bodyOverflow: getComputedStyle(document.body).overflow,
    }
  })
  expect(expandedLayout.x).toBeCloseTo(0, 0)
  expect(expandedLayout.y).toBeCloseTo(0, 0)
  expect(expandedLayout.width).toBeCloseTo(expandedLayout.viewportWidth, 0)
  expect(expandedLayout.height).toBeCloseTo(expandedLayout.viewportHeight, 0)
  expect(expandedLayout.shellOwnsViewportCenter).toBe(true)
  expect(expandedLayout.bodyOverflow).toBe('hidden')

  await page.getByRole('link', { name: 'Home', exact: true }).focus()
  expect(await page.locator('.mia-chat-shell').evaluate((shell) => shell.contains(document.activeElement))).toBe(true)

  const sendButton = page.getByRole('button', { name: 'Send message' })
  await sendButton.focus()
  await page.keyboard.press('Tab')
  expect(await page.locator('.mia-chat-shell').evaluate((shell) => shell.contains(document.activeElement))).toBe(true)
  await expect(sendButton).not.toBeFocused()

  await page.keyboard.press('Escape')
  await expect(page.getByRole('button', { name: 'Expand Ask Mia chat' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Expand Ask Mia chat' })).toBeFocused()
})

test('expanded desktop Ask Mia blocks background interaction and restores its trigger', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name.includes('mobile'), 'desktop-only modal boundary assertion')
  await page.goto('/#Ask%20Mia')

  const expandButton = page.getByRole('button', { name: 'Expand Ask Mia chat' })
  await expandButton.click()
  await expect(page.getByRole('dialog', { name: 'Ask Mia' })).toBeVisible()

  const clearButton = page.getByRole('button', { name: 'Clear', exact: true })
  await clearButton.click()
  const clearDialog = page.getByRole('dialog', { name: 'Clear this chat?' })
  await expect(clearDialog).toBeVisible()
  await expect(clearDialog.getByRole('button', { name: 'Keep chat' })).toBeFocused()
  await page.keyboard.press('Tab')
  await expect(clearDialog.getByRole('button', { name: 'Clear chat' })).toBeFocused()
  await page.keyboard.press('Escape')
  await expect(clearDialog).toBeHidden()
  await expect(clearButton).toBeFocused()

  await clearButton.click()
  await clearDialog.getByRole('button', { name: 'Clear chat' }).click()
  await expect(clearDialog).toBeHidden()
  await expect(clearButton).toBeHidden()
  await expect(page.getByRole('textbox', { name: 'Ask Mia', exact: true })).toBeFocused()

  await page.getByRole('link', { name: 'Home', exact: true }).focus()
  expect(await page.locator('.mia-chat-shell').evaluate((shell) => shell.contains(document.activeElement))).toBe(true)

  await page.locator('.mia-chat-backdrop').click({ position: { x: 2, y: 2 } })
  await expect(page.getByRole('dialog', { name: 'Ask Mia' })).toBeHidden()
  await expect(expandButton).toBeFocused()
})

test('incomplete participants get a short first session, private feedback, and a recoverable power-user path', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=participant')

  const firstSessionHeading = page.getByRole('heading', { name: 'Start with money in, money out.' })
  await firstSessionHeading.scrollIntoViewIfNeeded()
  await expect(firstSessionHeading).toBeVisible()
  if ((page.viewportSize()?.width ?? 1_000) <= 620) {
    const firstSessionColumns = await page.locator('.first-session-heading').evaluate((element) => getComputedStyle(element).gridTemplateColumns)
    expect(firstSessionColumns.split(' ')).toHaveLength(1)
  }
  await expect(page.getByRole('heading', { name: 'Give Mia a useful starting point.' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Guide', exact: true })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Feedback', exact: true })).toBeVisible()

  await page.getByRole('button', { name: 'Read the 3-minute guide' }).click()
  await expect(page.getByRole('heading', { name: 'A clear first Mia session in three moves.' })).toBeVisible()
  await expect(page.getByText(/pending drafts change nothing until you explicitly apply them/i)).toBeVisible()
  await expect(page.getByRole('dialog').getByRole('button', { name: 'Close' })).toBeFocused()
  await page.keyboard.press('Escape')
  await expect(page.getByRole('heading', { name: 'A clear first Mia session in three moves.' })).not.toBeVisible()

  await page.getByRole('button', { name: 'Test a private upload' }).click()
  await expect(page.getByRole('heading', { name: 'Upload evidence. Review draft facts. Apply only what is right.' })).toBeVisible()
  await page.getByRole('link', { name: 'Home', exact: true }).click()

  await page.getByRole('button', { name: 'Feedback', exact: true }).click()
  const feedback = page.getByRole('dialog')
  await feedback.getByLabel('Screen or workflow').selectOption('setup')
  await feedback.getByLabel('What did you attempt?').fill('I tried to save the first session form.')
  await feedback.getByLabel('What did you expect?').fill('I expected to return to Home.')
  await feedback.getByLabel('What happened instead?').fill('The save button stayed busy.')
  await feedback.getByRole('button', { name: 'Submit report' }).click()
  await expect(feedback.getByText('Report received.')).toBeVisible()
  await expect(feedback).toContainText('were not sent to analytics')
  await feedback.getByRole('button', { name: 'Return to Household CFO' }).click()

  await page.getByRole('button', { name: 'Give Mia my starting numbers' }).first().click()
  await expect(page.getByRole('heading', { name: 'Give Mia the basics for a useful first answer.' })).toBeVisible()
  await expect(page.getByText('Essential first-session information')).toBeVisible()
  await expect(page.locator('.setup-optional-fields')).toHaveCount(0)
  await expect(page.getByRole('heading', { name: 'Upload evidence. Review draft facts. Apply only what is right.' })).toHaveCount(0)
  const incomeInput = page.getByLabel('Primary monthly income')
  await expect(incomeInput).toHaveValue('')
  await incomeInput.click()
  await incomeInput.press('7')
  await expect(incomeInput).toHaveValue('7')
  await incomeInput.fill('7200')
  await expect(incomeInput).toHaveValue('7200')
  const fixedExpensesInput = page.getByLabel('Fixed essentials')
  await fixedExpensesInput.fill('2500')
  await expect(fixedExpensesInput).toHaveValue('2500')
  const flexibleSpendingInput = page.getByLabel('Flexible spending')
  await flexibleSpendingInput.fill('600')
  await expect(flexibleSpendingInput).toHaveValue('600')
  const setupRequestPromise = page.waitForRequest((request) => request.url().endsWith('/api/v1/workspace/setup') && request.method() === 'PATCH')
  await page.getByRole('button', { name: 'Save and talk to Mia' }).click()
  const setupRequest = await setupRequestPromise
  expect(setupRequest.postDataJSON().workspace).toMatchObject({
    primary_income: 7200,
    fixed_expenses: 2500,
    flexible_spend: 600,
    business_income: 0,
  })
  await expect(page.locator('.shell-header')).toHaveCount(1)
  await expect(page.getByRole('heading', { name: 'Tell Mia what changed.' })).toBeVisible()
  const miaComposer = page.getByRole('textbox', { name: 'Ask Mia', exact: true })
  await expect(miaComposer).toHaveValue('Based on my income, spending, and goal, what should I focus on first this month?')
  await expect(miaComposer).toBeFocused()

  await openSection(page, 'My Profile')
  const advancedProfile = page.locator('.setup-optional-fields')
  await expect(advancedProfile).toHaveCount(1)
  expect(await advancedProfile.evaluate((element: HTMLDetailsElement) => element.open)).toBe(false)

  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})

test('Mia explains when starting numbers have not been approved yet', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=participant#Ask%20Mia')

  const context = page.locator('.mia-context')
  await expect(context.getByRole('heading', { name: 'Add your starting numbers' })).toBeVisible()
  await expect(context).toContainText('Add and approve your starting household numbers')
  await expect(context.getByText('Approved data loaded')).toHaveCount(0)
})

test('ignored-only imports remain pending instead of becoming approved Mia context', async ({ page }) => {
  const ignoredImport = {
    id: 404,
    household_id: 77,
    document_kind: 'statement',
    status: 'applied',
    filename: 'ignored-statement.pdf',
    content_type: 'application/pdf',
    byte_size: 100,
    document_date: `${currentYear}-08-01`,
    period_start_on: `${currentYear}-08-01`,
    period_end_on: `${currentYear}-08-31`,
    extracted_summary: 'One transaction was extracted and ignored.',
    extraction_error: null,
    processed_at: `${currentYear}-08-16T01:00:00Z`,
    applied_at: `${currentYear}-08-16T01:05:00Z`,
    source_deleted_at: null,
    updated_at: `${currentYear}-08-16T01:05:00Z`,
    source_available: true,
    details_included: false,
    uploaded_by: null,
    applied_by: null,
    source_deleted_by: null,
    metadata: {},
    items: [],
    transaction_drafts: [{
      id: 405,
      occurred_on: `${currentYear}-08-05`,
      merchant: 'Ignored purchase',
      amount: 20,
      status: 'ignored',
      category_id: null,
      category_name: null,
    }],
    attempts: [],
  }
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  await page.route('http://api.test/api/v1/document_imports', (route) => route.fulfill({ status: 200, json: { document_imports: [ignoredImport] } }))
  await page.goto('/?pilot_e2e_role=participant')

  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()
  await expect(page.getByText('No approved document sources yet. Mia will use manual numbers until you apply extracted values.')).toBeVisible()

  await openSection(page, 'My Profile')
  await expect(page.getByText('Approved source', { exact: true }).locator('..')).toContainText('Not approved yet')
  await expect(page.getByText('Freshness', { exact: true }).locator('..')).toContainText('Review pending')
})

test('import review copy follows extracted results when a selected receipt produces household values', async ({ page }) => {
  const householdValueImport = {
    id: 505,
    household_id: 77,
    document_kind: 'receipt',
    status: 'needs_review',
    filename: 'profile-screenshot.png',
    content_type: 'image/png',
    byte_size: 24_000,
    document_date: null,
    period_start_on: null,
    period_end_on: null,
    extracted_summary: 'Mia found one household setup value.',
    extraction_error: null,
    processed_at: `${currentYear}-08-16T01:00:00Z`,
    applied_at: null,
    source_deleted_at: null,
    updated_at: `${currentYear}-08-16T01:00:00Z`,
    source_available: true,
    details_included: true,
    uploaded_by: null,
    applied_by: null,
    source_deleted_by: null,
    metadata: {
      declared_document_kind: 'receipt',
      document_kind_explicit: true,
      routing_resolved_kind: 'receipt',
      routing_source: 'participant_selection',
      routing_destination: 'transaction_review',
    },
    items: [{
      id: 506,
      target_type: 'expense_item',
      label: 'Fixed essentials',
      amount: 3_100,
      amount_cents: 310_000,
      balance: null,
      balance_cents: null,
      payment: null,
      payment_cents: null,
      cadence: 'monthly',
      source_type: null,
      stack_key: 'non_discretionary',
      account_type: null,
      debt_type: null,
      confidence: 'high',
      evidence: 'Profile screenshot',
      selected: true,
      ignored: false,
      applied_at: null,
      applied_record_type: null,
      applied_record_id: null,
      metadata: {},
    }],
    transaction_drafts: [],
    attempts: [],
  }
  let activeImport: unknown = householdValueImport
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  await page.route('http://api.test/api/v1/document_imports', (route) => route.fulfill({ status: 200, json: { document_imports: [activeImport] } }))
  await page.route('http://api.test/api/v1/document_imports/505', (route) => route.fulfill({ status: 200, json: { document_import: activeImport } }))
  await page.goto('/?pilot_e2e_role=participant')
  await openSection(page, 'My Profile')

  const result = page.locator('.document-routing-summary')
  await expect(result).toContainText('Review result')
  await expect(result).toContainText('1 household value → Household setup review')
  await expect(result).toContainText('You selected receipt/photo.')
  await expect(result).toContainText('sent the reviewable results she actually found to household setup review')
  await expect(result).toContainText('Nothing changed until you approve it.')
  await expect(result).not.toContainText('Mia honored the document type')

  activeImport = {
    ...householdValueImport,
    status: 'applied',
    applied_at: `${currentYear}-08-16T01:05:00Z`,
    items: householdValueImport.items.map((item) => ({ ...item, applied_at: `${currentYear}-08-16T01:05:00Z` })),
  }
  await page.reload()
  const resolvedResult = page.locator('.document-routing-summary')
  await expect(resolvedResult).toContainText('Review complete → Private import history')
  await expect(resolvedResult).toContainText('All extracted results are resolved.')
  await expect(resolvedResult).not.toContainText('Nothing changed until you approve it.')
})

test('admin cohort rows show only safe pilot progress signals', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=admin')
  await openSection(page, 'Admin')

  const inviteForm = page.locator('.admin-form').filter({ has: page.getByLabel('Email') }).first()
  await expect(inviteForm.getByLabel('First name')).toHaveCount(0)
  await expect(inviteForm.getByLabel('Last name')).toHaveCount(0)
  await expect(inviteForm.getByText("Names come from the invited person's Clerk account after first sign-in.")).toBeVisible()

  await expect(page.getByText('Setup started', { exact: true })).toBeVisible()
  await expect(page.getByText('Signed in', { exact: true })).toBeVisible()
  await expect(page.getByText('Review waiting', { exact: true })).toBeVisible()
  await expect(page.getByText(/Last safe activity:/)).toBeVisible()
  const participantRow = page.locator('.admin-user-row').filter({ hasText: 'participant@pilot.test' })
  await expect(participantRow.getByText(/profile completeness/i)).toHaveCount(0)
  await expect(participantRow.getByText(/readiness/i)).toHaveCount(0)
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})

test('admin can privately review and resolve submitted pilot feedback', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=admin')
  await openSection(page, 'Admin')

  const inbox = page.locator('.pilot-feedback-inbox')
  await expect(inbox.getByText('The upload stopped with a provider error.')).toBeVisible()
  await expect(inbox.getByText('participant@pilot.test', { exact: true })).toBeVisible()

  const statusRequest = page.waitForRequest((request) => request.url().endsWith('/api/v1/admin/pilot_feedback_reports/72') && request.method() === 'PATCH')
  await inbox.getByRole('button', { name: 'Mark reviewed' }).click()
  await statusRequest

  await expect(inbox.getByText('Feedback marked reviewed.')).toBeVisible()
  await expect(inbox.getByRole('button', { name: 'Reviewed 1' })).toBeVisible()
  await expect(inbox.getByText('Private Feedback Household')).toHaveCount(0)
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})

test('real review controls keep transaction and Mia changes behind explicit participant actions', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('link', { name: 'Budget', exact: true }).click()

  const transactionCard = page.locator('.transaction-draft-card').filter({ hasText: 'Dinner with friends' })
  await expect(transactionCard).toContainText('Actuals stay unchanged until you confirm.')
  const confirmRequest = page.waitForRequest((request) => request.url().endsWith('/api/v1/transaction_drafts/91/confirm') && request.method() === 'POST')
  await transactionCard.getByRole('button', { name: 'Confirm' }).click()
  await confirmRequest

  const miaCard = page.locator('.mia-action-draft-card').filter({ hasText: 'Move more into the unexpected sinking fund' })
  await expect(miaCard.getByRole('button', { name: 'Apply reviewed change' })).toBeEnabled()
  await expect(miaCard.getByRole('button', { name: 'Cancel draft' })).toBeEnabled()
  await expect(miaCard).toContainText('leave actual spending untouched')
  const cancelRequest = page.waitForRequest((request) => request.url().endsWith('/api/v1/mia_action_drafts/71/cancel') && request.method() === 'POST')
  await miaCard.getByRole('button', { name: 'Cancel draft' }).click()
  await cancelRequest
})

test('uncertain receipt splits stay reviewable and cannot be confirmed until categorized on mobile', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  let workspace = realWorkspaceData(true)
  const uncertainDraft = {
    id: 191,
    occurred_on: `${currentYear}-${String(new Date().getMonth() + 1).padStart(2, '0')}-16`,
    merchant: "Tita's Demo Market",
    amount: 70.25,
    amount_cents: 7_025,
    status: 'pending',
    source_type: 'receipt',
    financial_document_import_id: 700,
    category_id: 2,
    category_name: 'Dining out',
    splits: [
      { id: 501, budget_category_id: 2, category_name: 'Dining out', stack_key: 'discretionary', stack_label: 'Discretionary', amount: 42.15, amount_cents: 4_215, notes: 'Food items', confidence: 0.65, metadata: { category_match_status: 'matched', category_match_reason: 'item_text', extracted_category_name: 'Food' } },
      { id: 502, budget_category_id: null, category_name: 'Household supplies', stack_key: 'discretionary', stack_label: 'Discretionary', amount: 13.50, amount_cents: 1_350, notes: 'Cleaning products', confidence: 0.65, metadata: { category_match_status: 'needs_review', category_match_reason: 'no_strong_match', extracted_category_name: 'Household supplies' } },
      { id: 503, budget_category_id: null, category_name: 'Cigarettes', stack_key: 'discretionary', stack_label: 'Discretionary', amount: 11.25, amount_cents: 1_125, notes: 'Tobacco line', confidence: 0.65, metadata: { category_match_status: 'needs_review', category_match_reason: 'no_strong_match', extracted_category_name: 'Cigarettes' } },
      { id: 504, budget_category_id: null, category_name: 'Tax', stack_key: 'discretionary', stack_label: 'Discretionary', amount: 3.35, amount_cents: 335, notes: 'Sales tax', confidence: 0.65, metadata: { category_match_status: 'needs_review', category_match_reason: 'no_strong_match', extracted_category_name: 'Tax' } },
    ],
    matches: [],
  }
  workspace = {
    ...workspace,
    budget: {
      ...workspace.budget,
      annual_plan: {
        ...workspace.budget.annual_plan!,
        pending_transaction_drafts: [uncertainDraft],
      },
    },
  }

  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: workspace }))
  await page.route('http://api.test/api/v1/transaction_drafts/191', async (route) => {
    if (route.request().method() !== 'PATCH') return route.fallback()
    const payload = route.request().postDataJSON().transaction_draft
    const categoryNames = new Map([[1, 'Fixed essentials'], [2, 'Dining out'], [3, 'Expected sinking fund'], [4, 'Unexpected sinking fund']])
    const updatedDraft = {
      ...uncertainDraft,
      category_id: payload.splits[0].budget_category_id,
      category_name: categoryNames.get(payload.splits[0].budget_category_id) ?? null,
      splits: payload.splits.map((split: typeof uncertainDraft.splits[number]) => ({
        ...split,
        budget_category_id: split.budget_category_id,
        category_name: categoryNames.get(Number(split.budget_category_id)) ?? split.category_name,
      })),
    }
    workspace = {
      ...workspace,
      budget: {
        ...workspace.budget,
        annual_plan: {
          ...workspace.budget.annual_plan!,
          pending_transaction_drafts: [updatedDraft],
        },
      },
    }
    return route.fulfill({ status: 200, json: { transaction_draft: updatedDraft, workspace } })
  })

  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  const card = page.locator('.transaction-draft-card').filter({ hasText: "Tita's Demo Market" })
  await expect(card.getByText('3 splits need a category')).toBeVisible()
  await expect(card.getByText('Cleaning products')).toBeVisible()
  await expect(card.locator('.transaction-draft-impact-row.needs-category')).toContainText('Needs category$28.10 in this draft')
  await expect(card.getByRole('button', { name: 'Confirm', exact: true })).toBeDisabled()

  await card.getByRole('button', { name: 'Review categories' }).click()
  const categorySelects = card.getByLabel('Category')
  await expect(categorySelects).toHaveCount(4)
  await expect(categorySelects.nth(1)).toBeFocused()
  await categorySelects.nth(1).selectOption('1')
  await categorySelects.nth(2).selectOption('4')
  await categorySelects.nth(3).selectOption('2')
  const updateRequest = page.waitForRequest((request) => request.url().endsWith('/api/v1/transaction_drafts/191') && request.method() === 'PATCH')
  await card.getByRole('button', { name: 'Save draft' }).click()
  const request = await updateRequest
  expect(request.postDataJSON().transaction_draft.splits.map((split: { budget_category_id: number | null }) => split.budget_category_id)).toEqual([2, 1, 4, 2])
  await expect(card.getByText(/splits? need/)).toHaveCount(0)
  await expect(card.getByRole('button', { name: 'Confirm', exact: true })).toBeEnabled()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})

test('receipt category corrections refresh the selected import immediately', async ({ page }) => {
  const draft = {
    id: 192,
    occurred_on: `${currentYear}-${String(new Date().getMonth() + 1).padStart(2, '0')}-16`,
    merchant: "Tita's Demo Market",
    amount: 3.35,
    amount_cents: 335,
    status: 'pending',
    source_type: 'receipt',
    financial_document_import_id: 701,
    category_id: null,
    category_name: null,
    splits: [{
      id: 505,
      budget_category_id: null,
      category_name: 'Tax',
      stack_key: null,
      stack_label: null,
      amount: 3.35,
      amount_cents: 335,
      notes: 'Sales tax',
      confidence: 0.65,
      metadata: { category_match_status: 'needs_review', category_match_reason: 'no_strong_match', extracted_category_name: 'Tax' },
    }],
    matches: [],
  }
  let workspace = realWorkspaceData(true)
  workspace = {
    ...workspace,
    budget: {
      ...workspace.budget,
      annual_plan: {
        ...workspace.budget.annual_plan!,
        pending_transaction_drafts: [draft],
      },
    },
  }
  const documentImport = {
    id: 701,
    household_id: 77,
    document_kind: 'receipt',
    status: 'needs_review',
    filename: 'receipt.png',
    content_type: 'image/png',
    byte_size: 24_000,
    document_date: draft.occurred_on,
    period_start_on: null,
    period_end_on: null,
    extracted_summary: 'Mia found one transaction draft.',
    extraction_error: null,
    processed_at: `${currentYear}-08-16T01:00:00Z`,
    applied_at: null,
    source_deleted_at: null,
    updated_at: `${currentYear}-08-16T01:00:00Z`,
    source_available: true,
    details_included: true,
    uploaded_by: null,
    applied_by: null,
    source_deleted_by: null,
    metadata: {},
    items: [],
    transaction_drafts: [draft],
    attempts: [],
  }

  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: workspace }))
  await page.route('http://api.test/api/v1/document_imports', (route) => route.fulfill({ status: 200, json: { document_imports: [documentImport] } }))
  await page.route('http://api.test/api/v1/transaction_drafts/192', async (route) => {
    if (route.request().method() !== 'PATCH') return route.fallback()
    const payload = route.request().postDataJSON().transaction_draft
    const updatedDraft = {
      ...draft,
      category_id: 2,
      category_name: 'Dining out',
      splits: payload.splits.map((split: typeof draft.splits[number]) => ({
        ...split,
        budget_category_id: split.budget_category_id,
        category_name: 'Dining out',
        stack_key: 'discretionary',
        stack_label: 'Discretionary',
      })),
    }
    workspace = {
      ...workspace,
      budget: {
        ...workspace.budget,
        annual_plan: {
          ...workspace.budget.annual_plan!,
          pending_transaction_drafts: [updatedDraft],
        },
      },
    }
    return route.fulfill({ status: 200, json: { transaction_draft: updatedDraft, workspace } })
  })

  await page.goto('/?pilot_e2e_role=participant')
  await openSection(page, 'My Profile')
  const card = page.locator('.transaction-draft-card').filter({ hasText: "Tita's Demo Market" })
  await card.getByRole('button', { name: 'Review categories' }).click()
  await card.getByLabel('Category').selectOption('2')
  await card.getByRole('button', { name: 'Save draft' }).click()

  await expect(card.getByText(/splits? need/)).toHaveCount(0)
  await expect(card.locator('.transaction-draft-splits')).toContainText('Dining out')
  await expect(card.getByRole('button', { name: 'Confirm', exact: true })).toBeEnabled()
})

test('a late spending report cannot overwrite the refresh triggered by a transaction decision', async ({ page }) => {
  let requestCount = 0
  let markFirstRequestStarted: (() => void) | undefined
  const firstRequestStarted = new Promise<void>((resolve) => { markFirstRequestStarted = resolve })
  const reportCategory = (id: number, name: string, stackKey: string, stackLabel: string, planned: number, actual: number) => ({
    id, name, stack_key: stackKey, stack_label: stackLabel, planned, actual, pending: 0, remaining: planned - actual, active: true,
  })
  const currentMonthNumber = String(new Date().getMonth() + 1).padStart(2, '0')
  const reportShell = {
    period_label: `${currentMonth} ${currentYear}`,
    start_on: `${currentYear}-${currentMonthNumber}-01`,
    end_on: `${currentYear}-${currentMonthNumber}-28`,
    transactions: [],
    pending_drafts: [],
  }

  await page.route('http://api.test/api/v1/spending_report**', async (route) => {
    requestCount += 1
    if (requestCount === 1) {
      markFirstRequestStarted?.()
      await new Promise((resolve) => setTimeout(resolve, 500))
      return route.fulfill({
        status: 200,
        json: { spending_report: { ...reportShell, totals: { planned: 0, actual: 0, pending: 0, remaining: 0 }, categories: [] } },
      })
    }

    return route.fulfill({
      status: 200,
      json: {
        spending_report: {
          ...reportShell,
          totals: { planned: 5_300, actual: 4_000, pending: 0, remaining: 1_300 },
          categories: [
            reportCategory(1, 'Fixed essentials', 'non_discretionary', 'Non-discretionary', 4_000, 3_500),
            reportCategory(2, 'Dining out', 'discretionary', 'Discretionary', 450, 500),
            reportCategory(3, 'Expected sinking fund', 'sinking_expected', 'Sinking Fund — Expected', 600, 0),
            reportCategory(4, 'Unexpected sinking fund', 'sinking_unexpected', 'Sinking Fund — Unexpected', 250, 0),
          ],
        },
      },
    })
  })

  await page.goto('/?pilot_e2e_role=participant')
  await firstRequestStarted
  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  const transactionCard = page.locator('.transaction-draft-card').filter({ hasText: 'Dinner with friends' })
  await transactionCard.getByRole('button', { name: 'Confirm' }).click()

  const monthSummary = page.getByRole('region', { name: `${currentShortMonth} ${currentYear} plan position` })
  await expect(monthSummary.getByText('Confirmed actual', { exact: true }).locator('..')).toContainText('$4,000.00')
  await page.waitForTimeout(600)
  await expect(monthSummary.getByText('Confirmed actual', { exact: true }).locator('..')).toContainText('$4,000.00')
  expect(requestCount).toBeGreaterThanOrEqual(2)
})

test('a late Mia response cannot replace the ledger after the participant changes months', async ({ page }) => {
  const currentMonthIndex = new Date().getMonth()
  const targetMonthIndex = currentMonthIndex === 11 ? 10 : currentMonthIndex + 1
  const targetMonthNumber = String(targetMonthIndex + 1).padStart(2, '0')
  const currentMonthNumber = String(currentMonthIndex + 1).padStart(2, '0')
  const reportFor = (monthIndex: number, transactionLabel: string) => ({
    period_label: `${new Intl.DateTimeFormat('en-US', { month: 'long' }).format(new Date(currentYear, monthIndex, 1))} ${currentYear}`,
    start_on: `${currentYear}-${String(monthIndex + 1).padStart(2, '0')}-01`,
    end_on: `${currentYear}-${String(monthIndex + 1).padStart(2, '0')}-28`,
    totals: { planned: 5_300, actual: 125, pending: 0, remaining: 5_175 },
    categories: [],
    transactions: [{ id: monthIndex + 500, occurred_on: `${currentYear}-${String(monthIndex + 1).padStart(2, '0')}-12`, merchant: transactionLabel, amount: 125, amount_cents: 12_500, categories: ['Fixed essentials'], source_type: 'manual' }],
    pending_drafts: [],
  })
  const currentReport = reportFor(currentMonthIndex, 'STALE MIA MONTH')
  const targetReport = reportFor(targetMonthIndex, 'Selected month transaction')
  let releaseMiaResponse: (() => void) | undefined
  const miaResponseReleased = new Promise<void>((resolve) => { releaseMiaResponse = resolve })

  await page.route('http://api.test/api/v1/spending_report**', (route) => {
    const startOn = new URL(route.request().url()).searchParams.get('start_on')
    return route.fulfill({ status: 200, json: { spending_report: startOn?.includes(`-${targetMonthNumber}-`) ? targetReport : currentReport } })
  })
  await page.route('http://api.test/api/v1/mia/messages', async (route) => {
    if (route.request().method() !== 'POST') return route.fallback()
    await miaResponseReleased
    return route.fulfill({
      status: 200,
      json: {
        user_message: { id: 901, role: 'user', author: 'You', content: 'What should I focus on?', attachments: [] },
        assistant_message: { id: 902, role: 'assistant', author: 'Mia', content: 'Protect the baseline first.', attachments: [] },
        transaction_draft: null,
        mia_action_draft: null,
        budget: null,
        spending_report: { ...currentReport, start_on: `${currentYear}-${currentMonthNumber}-01`, end_on: `${currentYear}-${currentMonthNumber}-28` },
      },
    })
  })

  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()
  await page.getByRole('textbox', { name: 'Ask Mia', exact: true }).fill('What should I focus on?')
  await page.getByRole('button', { name: 'Send message to Mia' }).click()
  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  await page.getByLabel('Report month').selectOption(String(targetMonthIndex))
  await page.getByText('Monthly activity and transactions', { exact: true }).click()
  await expect(page.getByText('Selected month transaction')).toBeVisible()

  const completedMiaResponse = page.waitForResponse((response) => response.url().endsWith('/api/v1/mia/messages') && response.request().method() === 'POST')
  releaseMiaResponse?.()
  await completedMiaResponse
  await expect(page.getByText('Selected month transaction')).toBeVisible()
  await expect(page.getByText('STALE MIA MONTH')).toHaveCount(0)
})

test('a same-month Mia response cannot undo a newer transaction refresh', async ({ page }) => {
  const currentMonthNumber = String(new Date().getMonth() + 1).padStart(2, '0')
  const reportShell = {
    period_label: `${currentMonth} ${currentYear}`,
    start_on: `${currentYear}-${currentMonthNumber}-01`,
    end_on: `${currentYear}-${currentMonthNumber}-28`,
    categories: [],
    transactions: [],
    pending_drafts: [],
  }
  const staleReport = { ...reportShell, totals: { planned: 5_300, actual: 0, pending: 75, remaining: 5_225 } }
  const refreshedReport = {
    ...reportShell,
    totals: { planned: 5_300, actual: 4_000, pending: 0, remaining: 1_300 },
    categories: [
      { id: 1, name: 'Fixed essentials', stack_key: 'non_discretionary', stack_label: 'Non-discretionary', planned: 4_000, actual: 3_500, pending: 0, remaining: 500, active: true },
      { id: 2, name: 'Dining out', stack_key: 'discretionary', stack_label: 'Discretionary', planned: 450, actual: 500, pending: 0, remaining: -50, active: true },
      { id: 3, name: 'Expected sinking fund', stack_key: 'sinking_expected', stack_label: 'Sinking Fund — Expected', planned: 600, actual: 0, pending: 0, remaining: 600, active: true },
      { id: 4, name: 'Unexpected sinking fund', stack_key: 'sinking_unexpected', stack_label: 'Sinking Fund — Unexpected', planned: 250, actual: 0, pending: 0, remaining: 250, active: true },
    ],
  }
  let spendingReportRequests = 0
  let releaseMiaResponse: (() => void) | undefined
  const miaResponseReleased = new Promise<void>((resolve) => { releaseMiaResponse = resolve })

  await page.route('http://api.test/api/v1/spending_report**', (route) => {
    spendingReportRequests += 1
    return route.fulfill({ status: 200, json: { spending_report: spendingReportRequests > 1 ? refreshedReport : staleReport } })
  })
  await page.route('http://api.test/api/v1/mia/messages', async (route) => {
    if (route.request().method() !== 'POST') return route.fallback()
    await miaResponseReleased
    return route.fulfill({
      status: 200,
      json: {
        user_message: { id: 911, role: 'user', author: 'You', content: 'What should I focus on?', attachments: [] },
        assistant_message: { id: 912, role: 'assistant', author: 'Mia', content: 'Review complete.', attachments: [] },
        transaction_draft: null,
        mia_action_draft: null,
        budget: null,
        spending_report: staleReport,
      },
    })
  })

  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()
  await page.getByRole('textbox', { name: 'Ask Mia', exact: true }).fill('What should I focus on?')
  await page.getByRole('button', { name: 'Send message to Mia' }).click()
  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  const transactionCard = page.locator('.transaction-draft-card').filter({ hasText: 'Dinner with friends' })
  await transactionCard.getByRole('button', { name: 'Confirm' }).click()
  const monthSummary = page.getByRole('region', { name: `${currentShortMonth} ${currentYear} plan position` })
  await expect(monthSummary.getByText('Confirmed actual', { exact: true }).locator('..')).toContainText('$4,000.00')

  const completedMiaResponse = page.waitForResponse((response) => response.url().endsWith('/api/v1/mia/messages') && response.request().method() === 'POST')
  releaseMiaResponse?.()
  await completedMiaResponse
  await expect(monthSummary.getByText('Confirmed actual', { exact: true }).locator('..')).toContainText('$4,000.00')
  await expect(monthSummary.getByText('Pending review', { exact: true }).locator('..')).toContainText('$0.00')
})

test('failed receipt upload leaves the participant on a retryable private-upload state', async ({ page }) => {
  await page.route('http://api.test/api/v1/document_imports', async (route) => {
    if (route.request().method() === 'POST') return route.fulfill({ status: 422, json: { errors: ['Could not store document in private S3'] } })
    return route.fallback()
  })
  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('button', { name: 'Test a private upload' }).click()
  await expect(page.getByRole('heading', { name: 'Test one private file without changing your numbers.' })).toBeVisible()

  const receiptCard = page.locator('.document-upload-card').filter({ hasText: 'Receipt or quick evidence' })
  await receiptCard.locator('input[type="file"]').setInputFiles({
    name: 'receipt.png', mimeType: 'image/png', buffer: Buffer.from('not-a-real-financial-document'),
  })
  await expect(page.getByRole('alert')).toContainText('Could not store document in private S3')
  await expect(receiptCard.getByText('Choose file', { exact: true })).toBeVisible()
  await expect(receiptCard.locator('input[type="file"]')).toBeEnabled()
})
