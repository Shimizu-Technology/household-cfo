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
    monthly_income: 14_200, fixed_expenses: 6_000, flexible_spend: 1_500, debt_payments: 500,
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
  planned_outflow: index === 11 ? 8_300 : 5_300,
  baseline_surplus: (index >= 7 ? 15_000 : 14_200) - (index === 11 ? 8_300 : 5_300),
  expected_irregular: index === 11 ? 3_000 : 0,
  expected_contributors: index === 11 ? [{ name: 'Holiday travel', amount: 3_000 }] : [],
}))

const budget = {
  framework: 'Expense Stack', intro: 'Annual household plan', monthly_income: 14_200,
  total_monthly_outflow: 5_300, baseline_surplus: 8_900,
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
    income_sources: [{
      id: 1, label: 'Primary income', source_type: 'job', base_amount: 14_200, base_cadence: 'monthly',
      schedule_entries: [{ id: 1, entry_type: 'recurring_change', label: null, amount: 15_000, cadence: 'monthly', effective_on: `${currentYear}-08-01` }],
    }],
    annual_outlook: {
      typical_monthly_outflow: 5_300,
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
  const responses: Record<string, unknown> = {
    '/api/demo/profile': profile,
    '/api/demo/dashboard': dashboard,
    '/api/demo/budget': budget,
    '/api/demo/wealth': wealth,
    '/api/demo/optionality': optionality,
    '/api/demo/cfo-filter': cfoFilter,
    '/api/demo/mia/messages': { messages: chatMessages(), oldest_message_id: 1, older_message_count: 0, has_older_messages: false, quick_prompts: ['Can I buy the purse?', 'Why is my readiness Red?', 'Emergency fund or debt first?', 'Can I leave my job?'], disclaimer: 'Education only.' },
  }

  await page.route('http://api.test/**', async (route) => {
    const path = new URL(route.request().url()).pathname
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
  await page.goto('/')
})

test('Home centers review work and keeps Red guidance internally consistent', async ({ page }) => {
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
  await expect(chartDetail).toContainText('$5,300.00')
  await expect(chartDetail).toContainText('$8,900.00 remains after planned outflow.')
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
  await page.getByRole('button', { name: 'Ask Mia', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Why is my readiness Red?' })).toBeVisible()
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
  await page.getByRole('button', { name: 'Budget', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'Set it once, then schedule what changes.' })).toBeVisible()
  await expect(page.getByText('Recurring amount changes')).toBeVisible()
  await expect(page.getByText('$15,000.00 Monthly')).toBeVisible()
  await expect(page.getByRole('heading', { name: 'See the expensive months before they arrive.' })).toBeVisible()
  await expect(page.getByText('Dec spending spike')).toBeVisible()
  await expect(page.getByText('Holiday travel')).toBeVisible()
  await expect(page.getByRole('heading', { name: 'See which layer is using the plan.' })).toBeVisible()
  await expect(page.locator('.expense-stack-row')).toHaveCount(4)
  await expect(page.getByText('$75.00 pending review—not included in actuals.')).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Every category, ordered by pressure' })).toBeVisible()
  await expect(page.locator('.annual-outlook .cash-flow-month')).toHaveCount(12)
  const diningDraft = page.locator('.transaction-draft-card').filter({ hasText: 'Dinner with friends' })
  await expect(diningDraft.getByRole('region', { name: new RegExp(`Budget impact if approved for ${currentShortMonth}`) })).toContainText('$100.00 over plan if approved.')
  await expect(diningDraft).toContainText('Actuals stay unchanged until you confirm.')
})

test('participant navigation remains available after deep scrolling', async ({ page }) => {
  await page.getByRole('button', { name: 'Budget', exact: true }).click()
  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight))
  await expect(page.locator('.tabs-shell')).toBeInViewport()
  const top = await page.locator('.tabs-shell').evaluate((element) => Math.round(element.getBoundingClientRect().top))
  expect(top).toBe(0)
  await page.getByRole('button', { name: 'Home', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'CFO snapshot' })).toBeVisible()
})

test('Wealth and Optionality explain decisions without fake payoff progress or conflicting scores', async ({ page }) => {
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

  const statusCard = page.locator('.mia-status-card')
  const headingBox = await statusCard.locator('strong').boundingBox()
  const copyBox = await statusCard.locator('p').boundingBox()
  expect(headingBox).not.toBeNull()
  expect(copyBox).not.toBeNull()
  expect((headingBox?.width ?? 0)).toBeGreaterThan(80)
  expect((headingBox?.y ?? 0) + (headingBox?.height ?? 0)).toBeLessThanOrEqual((copyBox?.y ?? 0) + 1)
  await expect(page.getByText('Swipe for more →')).toBeVisible()
  await expect(page.locator('.home-financial-visuals .cash-flow-month')).toHaveCount(12)
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})
