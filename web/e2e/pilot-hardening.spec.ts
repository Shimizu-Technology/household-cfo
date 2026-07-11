import { expect, test, type Page } from '@playwright/test'

const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
const currentMonth = new Intl.DateTimeFormat('en-US', { month: 'long' }).format(new Date())
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

const monthRows = months.map((label, index) => ({
  period_id: index + 1, allocation_id: index + 1, planned: 9_080,
  actual: label === new Intl.DateTimeFormat('en-US', { month: 'short' }).format(new Date()) ? 250 : 0,
  remaining: label === new Intl.DateTimeFormat('en-US', { month: 'short' }).format(new Date()) ? 8_830 : 9_080,
}))

const budget = {
  framework: 'Expense Stack', intro: 'Annual household plan', monthly_income: 14_200,
  total_monthly_outflow: 9_405, baseline_surplus: 4_795,
  stacks: [
    { label: 'Non-discretionary', color: 'red', amount: 3_000, description: 'Fixed', examples: [] },
    { label: 'Discretionary', color: 'yellow', amount: 1_000, description: 'Flexible', examples: [] },
  ],
  custom_categories_note: 'Use household language.',
  annual_plan: {
    year: currentYear,
    months: months.map((label, index) => ({ id: index + 1, label, starts_on: `${currentYear}-${String(index + 1).padStart(2, '0')}-01`, ends_on: `${currentYear}-${String(index + 1).padStart(2, '0')}-28`, status: 'open' })),
    rows: [{ id: 1, name: 'Fixed essentials', stack_key: 'non_discretionary', stack_label: 'Non-discretionary', active: true, months: monthRows, planned_total: 108_960, actual_total: 250 }],
    monthly_income: Object.fromEntries(months.map((_, index) => [index + 1, 14_200])),
    pending_transaction_drafts: [], pending_mia_action_drafts: [], recent_transactions: [], archived_categories: [],
  },
}

const wealth = { summary: { net_worth: 12_345_678.9, liquid_net_worth: 1_234_567.89, retirement_projection: 98_765_432.1, monthly_wealth_building: 12_345.67 }, milestones: [], guidance: 'Protect options.' }
const optionality = { scenario: 'Founder transition', question: 'Can I leave my job?', target_runway_months: 6, current_runway_months: 0.5, monthly_gap: 4_795, choices: [], levers: [{ label: 'Green runway gap', amount: 51_430 }, { label: 'Annual income protected', amount: 170_400 }] }
const cfoFilter = { framework: 'CFO Filter', prompt: 'Pressure-test the move.', decisions: [{ item: 'Large planned purchase', amount: 1_234_567.89, recommendation: 'Wait', reason: 'Protect runway first.' }], targets: [], priority_stack: ['Essential bills', 'Expected expenses', 'Runway'] }

function chatMessages(count = 125) {
  return Array.from({ length: count }, (_, index) => ({
    id: index + 1,
    role: index % 2 === 0 ? 'user' : 'assistant',
    author: index % 2 === 0 ? 'You' : 'Mia',
    content: `Message ${index + 1}`,
    attachments: index === count - 1 ? [{
      filename: 'receipt.png', content_type: 'image/png', document_kind: 'receipt', status: 'applied',
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
      const selectors = '.metric-card strong, .stack-card strong, .decision-card > strong, .readiness-milestone-card > strong'
      const values = Array.from(document.querySelectorAll<HTMLElement>(selectors)).filter((element) => element.offsetParent !== null)
      return {
        documentOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
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

    expect(audit.documentOverflow, `${section} should not overflow horizontally`).toBeLessThanOrEqual(1)
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

  await page.getByRole('button', { name: 'Load earlier messages (40 remaining)' }).click()
  await expect(page.locator('.message-row')).toHaveCount(100)
  await expect(page.locator('.chat-history-load')).toHaveCount(0)
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
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})
