import { expect, test, type Page } from '@playwright/test'

const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
const currentMonth = new Intl.DateTimeFormat('en-US', { month: 'long' }).format(new Date())
const currentShortMonth = new Intl.DateTimeFormat('en-US', { month: 'short' }).format(new Date())
const currentYear = new Date().getFullYear()

const profile = {
  household: { name: 'Pilot Household', stage: 'First cohort', location: 'Guam', primary_goal: 'Build a calm annual rhythm.' },
  coach: { name: 'Mia', role: 'AI coach', voice: 'Warm and direct' },
  members: [], priorities: [], completeness: 100, uploads: [], sections: [],
}

const dashboard = {
  summary: {
    monthly_income: 14_200, fixed_expenses: 6_000, flexible_spend: 1_500, debt_payments: 200,
    savings_rate_percent: 38, runway_months: 0.5, next_safe_to_spend_amount: 0,
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

function categoryMonths(categoryId: number, planned: number, currentActual: number) {
  return months.map((label, index) => {
    const actual = label === currentShortMonth ? currentActual : 0
    return {
      period_id: index + 1,
      allocation_id: categoryId * 100 + index + 1,
      planned,
      actual,
      remaining: planned - actual,
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
      { id: 3, name: 'Expected sinking fund', stack_key: 'sinking_expected', stack_label: 'Sinking Fund — Expected', active: true, months: categoryMonths(3, 600, 200), planned_total: 7_200, actual_total: 200 },
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
  summary: { net_worth: 12_345_678.9, liquid_net_worth: 1_234_567.89, retirement_projection: 98_765_432.1, monthly_wealth_building: 12_345.67 },
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
  items: [{ id: 711, action_type: 'update_allocation', target_record_type: 'BudgetCategory', target_record_id: 4, label: 'Unexpected sinking fund', description: 'Increase the monthly plan after review.', payload: { changes: [{ month: 8 }] }, before_snapshot: {}, after_snapshot: {} }],
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

test.beforeEach(async ({ page }) => {
  await mockDemoApi(page)
  await page.addInitScript((messages) => {
    window.localStorage.setItem('household-cfo:mia-chat:v1:preview', JSON.stringify(messages))
  }, chatMessages(100))
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
  await expect(monthSummary).toContainText('Readiness-aware CFO amount—not ordinary budget remaining.')
  await expect(monthSummary).toContainText('$1,710.00 remains after pending review')
  const homeOutflowBreakdown = monthSummary.getByRole('group', { name: 'Monthly money out breakdown' })
  await expect(homeOutflowBreakdown).toContainText('Category plan')
  await expect(homeOutflowBreakdown).toContainText('$5,300.00')
  await expect(homeOutflowBreakdown).toContainText('Debt minimums')
  await expect(homeOutflowBreakdown).toContainText('$200.00')
  await expect(homeOutflowBreakdown).toContainText('Total money out')
  await expect(homeOutflowBreakdown).toContainText('$5,500.00')
  await expect(monthSummary.locator('.budget-progress-pending')).toBeVisible()
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
})

test('large financial values stay on one line and participant screens stay inside the viewport', async ({ page }) => {
  await page.goto('/')
  for (const section of ['Home', 'Ask Mia', 'My Profile', 'Budget', 'Wealth', 'CFO Filter', 'Optionality']) {
    if (section !== 'Home') await page.getByRole('button', { name: section, exact: true }).click()

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
  await page.getByRole('button', { name: 'Ask Mia', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Why is my readiness Red?' })).toBeVisible()
  await expect(page.getByText('More prompts →')).toBeVisible()
  await expect(page.locator('.message-row')).toHaveCount(60)
  await expect(page.getByRole('button', { name: 'Load earlier messages (40 remaining)' })).toBeVisible()
  await expect(page.locator('.message-attachment-card img')).toHaveAttribute('loading', 'lazy')
  await expect(page.getByRole('button', { name: 'Review draft' })).toBeVisible()

  await page.getByRole('button', { name: 'Review draft' }).click()
  await expect(page.getByText('Profile completeness', { exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'Ask Mia', exact: true }).click()

  await page.getByRole('button', { name: 'Load earlier messages (40 remaining)' }).click()
  await expect(page.locator('.message-row')).toHaveCount(100)
  await expect(page.locator('.chat-history-load')).toHaveCount(0)
})

test('Budget explains scheduled income changes and upcoming annual pressure', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('button', { name: 'Budget', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'Money in, money out, and what is left.' })).toBeVisible()
  const outflowBreakdown = page.getByRole('group', { name: 'Monthly money out breakdown' })
  await expect(outflowBreakdown).toContainText('Category plan')
  await expect(outflowBreakdown).toContainText('$5,300.00')
  await expect(outflowBreakdown).toContainText('Debt minimums')
  await expect(outflowBreakdown).toContainText('$200.00')
  await expect(outflowBreakdown).toContainText('Total money out')
  await expect(outflowBreakdown).toContainText('$5,500.00')
  const annualMoneyOut = page.getByLabel('Annual money out breakdown')
  await expect(annualMoneyOut).toContainText('Annual category plan$63,600.00')
  await expect(annualMoneyOut).toContainText('Annual debt minimums$2,400.00')
  await expect(annualMoneyOut).toContainText('Total annual money out$66,000.00')
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

test('focused manual budget tools expose exact controls without a page hunt and protect dirty edits', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('button', { name: 'Budget', exact: true }).click()
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
  await page.getByRole('button', { name: 'Cancel', exact: true }).click()
  await expect(manager).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Manage manually' })).toBeFocused()

  await page.getByRole('button', { name: 'Ask Mia to update my plan' }).click()
  const composer = page.getByRole('textbox', { name: 'Ask Mia' })
  await expect(composer).toBeFocused()
  await expect(composer).toHaveValue('I want to update my budget. Help me make this change safely: ')
})

test('participant navigation remains available after deep scrolling', async ({ page }) => {
  await page.goto('/')
  await page.getByRole('button', { name: 'Budget', exact: true }).click()
  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight))
  await expect(page.locator('.tabs-shell')).toBeInViewport()
  const top = await page.locator('.tabs-shell').evaluate((element) => Math.round(element.getBoundingClientRect().top))
  expect(top).toBe(0)
  await page.getByRole('button', { name: 'Home', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'CFO snapshot' })).toBeVisible()
  await expect.poll(() => page.evaluate(() => Math.round(window.scrollY))).toBe(0)
  await expect(page.locator('.shell-header')).not.toHaveClass(/is-compact/)
})

test('Wealth and Optionality explain decisions without fake payoff progress or conflicting scores', async ({ page }) => {
  await page.goto('/')
  await page.getByRole('button', { name: 'Wealth', exact: true }).click()
  const debtCard = page.getByRole('heading', { name: 'Debt payoff' }).locator('..')
  await expect(debtCard.getByText('$5,400.00 remaining')).toBeVisible()
  await expect(debtCard.locator('.progress-track')).toHaveCount(0)
  await expect(debtCard).not.toContainText('0 / 5,400')

  await page.getByRole('button', { name: 'Optionality', exact: true }).click()
  await expect(page.getByText('Best fit now')).toBeVisible()
  await expect(page.getByText('Build runway first')).toBeVisible()
  await expect(page.getByText('Not ready yet', { exact: true })).toBeVisible()
  await expect(page.getByText(/\/100 readiness/)).toHaveCount(0)
})

test('compact phone layouts keep the status card legible and expose horizontal navigation', async ({ page }, testInfo) => {
  test.skip(!testInfo.project.name.includes('mobile'), 'mobile-only responsive assertion')
  await page.goto('/')

  const statusCard = page.locator('.mia-status-card')
  const headingBox = await statusCard.locator('strong').boundingBox()
  const copyBox = await statusCard.locator('p').boundingBox()
  expect(headingBox).not.toBeNull()
  expect(copyBox).not.toBeNull()
  expect((headingBox?.width ?? 0)).toBeGreaterThan(80)
  expect((headingBox?.y ?? 0) + (headingBox?.height ?? 0)).toBeLessThanOrEqual((copyBox?.y ?? 0) + 1)
  await expect(page.getByText('Swipe for more →')).toBeVisible()
  await expect(page.locator('.home-financial-visuals .cash-flow-month')).toHaveCount(12)
  await page.getByRole('button', { name: 'Ask Mia', exact: true }).click()
  await expect(page.locator('.shell-header')).toHaveClass(/is-compact/)
  await expect(page.getByText('More prompts →')).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
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
  await expect(page.getByText('Give Mia a useful starting point', { exact: true })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Tester guide' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Report a problem' })).toBeVisible()

  await page.getByRole('button', { name: 'Read the 3-minute guide' }).click()
  await expect(page.getByRole('heading', { name: 'A clear first Mia session in three moves.' })).toBeVisible()
  await expect(page.getByText('Pending drafts change nothing by themselves.')).toBeVisible()
  await expect(page.getByRole('dialog').getByRole('button', { name: 'Close' })).toBeFocused()
  await page.keyboard.press('Escape')
  await expect(page.getByRole('heading', { name: 'A clear first Mia session in three moves.' })).not.toBeVisible()

  await page.getByRole('button', { name: 'Test a private upload' }).click()
  await expect(page.getByRole('heading', { name: 'Upload evidence. Review draft facts. Apply only what is right.' })).toBeVisible()
  await page.getByRole('button', { name: 'Home', exact: true }).click()

  await page.getByRole('button', { name: 'Report a problem' }).click()
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
  await expect(page.locator('.shell-header')).toHaveClass(/is-compact/)
  await expect(page.getByRole('heading', { name: 'Ask Mia for the CFO read.' })).toBeVisible()
  const miaComposer = page.getByRole('textbox', { name: 'Ask Mia', exact: true })
  await expect(miaComposer).toHaveValue('Based on my income, spending, and goal, what should I focus on first this month?')
  await expect(miaComposer).toBeFocused()

  await page.getByRole('button', { name: 'My Profile', exact: true }).click()
  const advancedProfile = page.locator('.setup-optional-fields')
  await expect(advancedProfile).toHaveCount(1)
  expect(await advancedProfile.evaluate((element: HTMLDetailsElement) => element.open)).toBe(false)

  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
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

  await page.getByRole('button', { name: 'Ask Mia', exact: true }).click()
  await expect(page.getByText('No approved document sources yet. Mia will use manual numbers until you apply extracted values.')).toBeVisible()

  await page.getByRole('button', { name: 'My Profile', exact: true }).click()
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
  await page.getByRole('button', { name: 'My Profile', exact: true }).click()

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
  await page.getByRole('button', { name: 'Admin', exact: true }).click()

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
  await page.getByRole('button', { name: 'Admin', exact: true }).click()

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
  await page.getByRole('button', { name: 'Budget', exact: true }).click()

  const transactionCard = page.locator('.transaction-draft-card').filter({ hasText: 'Dinner with friends' })
  await expect(transactionCard).toContainText('Actuals stay unchanged until you confirm.')
  const confirmRequest = page.waitForRequest((request) => request.url().endsWith('/api/v1/transaction_drafts/91/confirm') && request.method() === 'POST')
  await transactionCard.getByRole('button', { name: 'Confirm' }).click()
  await confirmRequest

  const miaCard = page.locator('.mia-action-draft-card').filter({ hasText: 'Move more into the unexpected sinking fund' })
  await expect(miaCard.getByRole('button', { name: 'Apply budget edit' })).toBeEnabled()
  await expect(miaCard.getByRole('button', { name: 'Cancel draft' })).toBeEnabled()
  await expect(miaCard).toContainText('leave actual spending untouched')
  const cancelRequest = page.waitForRequest((request) => request.url().endsWith('/api/v1/mia_action_drafts/71/cancel') && request.method() === 'POST')
  await miaCard.getByRole('button', { name: 'Cancel draft' }).click()
  await cancelRequest
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
  await page.getByRole('button', { name: 'Budget', exact: true }).click()
  const transactionCard = page.locator('.transaction-draft-card').filter({ hasText: 'Dinner with friends' })
  await transactionCard.getByRole('button', { name: 'Confirm' }).click()

  const monthSummary = page.getByRole('region', { name: `${currentShortMonth} ${currentYear} plan position` })
  await expect(monthSummary.getByText('Confirmed actual', { exact: true }).locator('..')).toContainText('$4,000.00')
  await page.waitForTimeout(600)
  await expect(monthSummary.getByText('Confirmed actual', { exact: true }).locator('..')).toContainText('$4,000.00')
  expect(requestCount).toBeGreaterThanOrEqual(2)
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
