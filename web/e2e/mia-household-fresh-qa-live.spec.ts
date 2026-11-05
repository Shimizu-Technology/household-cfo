import { expect, test, type Page, type TestInfo } from '@playwright/test'
import { mkdir, writeFile } from 'node:fs/promises'

// Synthetic W20 household: November join, reviewed October spending $2,254.65,
// income $4,500, costs $3,000, debt minimums $95, no entered account balances.
const liveUrl = process.env.HCFO_MIA_FRESH_LIVE_URL
const apiUrl = process.env.HCFO_MIA_FRESH_API_URL ?? 'http://127.0.0.1:3222'
const evidenceDir = process.env.HCFO_MIA_FRESH_EVIDENCE_DIR
const setupUrl = process.env.HCFO_MIA_SETUP_LIVE_URL
const modelUrl = process.env.HCFO_MIA_TWO_MODEL_CALLS_URL
const setupLinkUrl = process.env.HCFO_MIA_SETUP_LINK_URL
const purchaseConfirmUrl = process.env.HCFO_MIA_PURCHASE_CONFIRM_URL
const headers = { Authorization: 'Bearer test_token:e2e_participant:participant@pilot.test:Test:Participant', 'X-Cohort-Id': '1' }

test('BOG UI late review selected periods corrected prices and food preserve reviewed money', async ({ page, request }, info) => {
  test.skip(!liveUrl, 'Requires the isolated W20 real Rails fixture; no mocked API responses.')
  test.setTimeout(240_000)
  if (info.project.name === 'desktop-chrome') await page.setViewportSize({ width: 1366, height: 900 })
  const workspace = async () => {
    const response = await request.get(`${apiUrl}/api/v1/workspace`, { headers })
    expect(response.ok()).toBe(true)
    return response.json()
  }
  const before = await workspace()
  await page.goto(`${liveUrl}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Budget`)
  await expect(page.getByLabel('Report month')).toBeVisible({ timeout: 30_000 })
  await page.getByLabel('Report month').selectOption('11')
  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()
  const selected = await send(page, 'Can I buy a $300 stroller?')
  expect(selected.assistant_message.content).toContain('December 2026')
  await capture(page, info, 'late-selected-december', selected)
  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  await page.getByLabel('Report month').selectOption('10')
  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()
  const corrected = await send(page, 'Can I afford a $300 stroller? No, it costs $400')
  expect(corrected.assistant_message.content).toMatch(/\$400.*\$1,005/)
  expect(corrected.transaction_draft).toBeNull()
  expect(corrected.mia_action_draft).toBeNull()
  await capture(page, info, 'late-corrected-price', corrected)
  const ambiguous = await send(page, 'Can I buy a $300 stroller? Actually, the price is $400 or $450')
  expect(ambiguous.assistant_message.content).toMatch(/which.*price/i)
  const namedPrice = await send(page, 'Can I buy a $300 stroller? The stroller costs $400')
  expect(namedPrice.assistant_message.content).toMatch(/which.*price/i)
  const recurring = await send(page, 'Can I buy a $120 monthly gym membership?')
  expect(recurring.assistant_message.content).toMatch(/recurring monthly commitment/)
  const food = await send(page, 'Can I buy a $300 stroller? I missed meals so my kids could eat, but my food budget is empty')
  expect(food.assistant_message.content).toMatch(/food.*today|eat.*today/i)
  expect(food.assistant_message.content).not.toContain('The $300 purchase')
  await capture(page, info, 'late-food-before-budget', food)
  const purse = await send(page, 'Can I buy a $500 purse? No, it costs $600')
  expect(purse.assistant_message.content).toContain('$600 purse')
  const after = await workspace()
  expect(after.dashboard.month_answer).toEqual(before.dashboard.month_answer)
  expect(after.workspace.setup_values).toEqual(before.workspace.setup_values)
  await capture(page, info, 'late-unchanged-money', { before: before.dashboard.month_answer, after: after.dashboard.month_answer })
})

async function send(page: Page, message: string) {
  const composer = page.getByRole('textbox', { name: 'Ask Mia', exact: true })
  await expect(page.getByRole('button', { name: 'Mia is thinking', exact: true })).toHaveCount(0, { timeout: 30_000 })
  await expect(composer).toBeEditable({ timeout: 30_000 })
  await composer.fill(message)
  await expect(composer).toHaveValue(message)
  await expect(page.getByRole('button', { name: 'Send message to Mia', exact: true })).toBeEnabled()
  const result = page.waitForResponse(response => response.url().includes('/api/v1/mia/messages') && response.request().method() === 'POST' && response.request().postDataJSON()?.message === message)
  await page.getByRole('button', { name: 'Send message to Mia', exact: true }).click()
  const response = await result
  expect(response.status(), await response.text()).toBe(201)
  return response.json()
}

async function capture(page: Page, info: TestInfo, name: string, data?: unknown) {
  if (!evidenceDir) return
  await mkdir(`${evidenceDir}/shots`, { recursive: true })
  const path = `${evidenceDir}/shots/${info.project.name}-${name}.png`
  await page.screenshot({ path, fullPage: true })
  await info.attach(name, { path, contentType: 'image/png' })
  if (data) await writeFile(`${evidenceDir}/${info.project.name}-${name}.json`, JSON.stringify(data, null, 2))
}

test('BOG UI household fresh QA answers agree with Home and preserve reviewed money', async ({ page, request }, info) => {
  test.skip(!liveUrl, 'Requires the isolated W20 real Rails fixture; no mocked API responses.')
  test.setTimeout(180_000)
  if (info.project.name === 'desktop-chrome') await page.setViewportSize({ width: 1366, height: 900 })
  await page.goto(`${liveUrl}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Home`)
  await expect(page.getByText('$1,405', { exact: true }).first()).toBeVisible({ timeout: 60_000 })
  await expect(page.getByText('Not known yet', { exact: true })).toBeVisible()
  await capture(page, info, 'home-unknown-spending')
  const homeAccounts = page.getByRole('button', { name: 'Add account balances', exact: true })
  expect((await homeAccounts.boundingBox())?.height).toBeGreaterThanOrEqual(44)
  await homeAccounts.click()
  await expect(page.getByRole('heading', { name: 'Your household money', exact: true })).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Keep one approved balance for each household asset.', exact: true })).toBeVisible()
  await capture(page, info, 'cushion-link-accounts')
  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()

  const month = await send(page, 'How am I doing this month?')
  expect(month.assistant_message.setup_help.money_inputs).toContain('accounts')
  const miaAccounts = page.getByRole('button', { name: 'Add account balances', exact: true }).last()
  expect((await miaAccounts.boundingBox())?.height).toBeGreaterThanOrEqual(44)
  await capture(page, info, 'mia-missing-account-link', month)
  await miaAccounts.click()
  await expect(page.getByRole('heading', { name: 'Keep one approved balance for each household asset.', exact: true })).toBeVisible()
  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()

  const august = await send(page, 'How did I do in August?')
  expect(august.assistant_message.content).toContain('Your plan starts in November 2026')
  expect(august.assistant_message.content).toContain('not known yet')
  expect(august.assistant_message.content).not.toMatch(/\$0|over the plan|under the plan|exactly/)
  await capture(page, info, 'august-no-plan', august)

  const october = await send(page, 'How did I do in October?')
  expect(october.assistant_message.content).toContain('$2,254.65')
  expect(october.assistant_message.content).toContain('no plan to compare against')
  expect(october.assistant_message.content).not.toMatch(/over the plan|under the plan|exactly/)
  await capture(page, info, 'october-reviewed-spending', october)

  const purchase = await send(page, 'Can I afford a $300 stroller?')
  expect(purchase.assistant_message.content).toMatch(/\$300.*\$1,105.*\$1,405/)
  expect(purchase.assistant_message.content).toContain('plan figure')
  expect(purchase.assistant_message.content).not.toMatch(/Plaid|liquid account picture|unapproved/)
  expect(purchase.mia_action_draft).toBeNull()
  expect(purchase.transaction_draft).toBeNull()
  await capture(page, info, 'stroller-plan-answer', purchase)

  const food = await send(page, 'I skipped meals this week so the kids could eat')
  expect(food.assistant_message.content).toMatch(/food.*today/i)
  expect(food.assistant_message.content).toContain('coach')
  expect(food.assistant_message.content).not.toMatch(/which bill|proud|great job|discipline/i)
  await capture(page, info, 'food-first', food)

  const hardship = await send(page, 'I lost my job hours and I cannot pay rent')
  expect(hardship.assistant_message.content).toContain('coach')
  await capture(page, info, 'hardship-coach-help', hardship)
  const budget = await request.get(`${apiUrl}/api/v1/budget`, { headers })
  expect(budget.ok()).toBe(true)
  const saved = await budget.json()
  expect(saved.annual_plan.recent_transactions).toHaveLength(1)
  expect(saved.annual_plan.pending_transaction_drafts).toHaveLength(0)
})

test('BOG UI household live model gives a plan comparison and hears skipped meals', async ({ page }, info) => {
  test.skip(!modelUrl, 'Opt-in only: uses three reserved live participant requests.')
  test.setTimeout(180_000)
  await page.goto(`${modelUrl}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Ask%20Mia`)
  const purchase = await send(page, 'Can I afford a $300 stroller?')
  expect(purchase.assistant_message.content).toContain('$300')
  expect(purchase.assistant_message.content).toMatch(/plan/i)
  expect(purchase.mia_action_draft).toBeNull()
  expect(purchase.transaction_draft).toBeNull()
  for (const [width, height] of [[390, 844], [320, 568], [1366, 900]]) {
    await page.setViewportSize({ width, height })
    await capture(page, info, `live-stroller-${width}`, purchase)
  }
  const food = await send(page, "I've been skipping meals so the kids could eat")
  expect(food.assistant_message.content).toMatch(/food|meals|eat/i)
  expect(food.assistant_message.content).toContain('coach')
  expect(food.assistant_message.content).toContain('today')
  expect(food.assistant_message.content).not.toMatch(/which bill|proud|great job|discipline/i)
  for (const [width, height] of [[390, 844], [320, 568], [1366, 900]]) {
    await page.setViewportSize({ width, height })
    await capture(page, info, `live-food-${width}`, food)
  }
  const hardship = await send(page, 'Can I afford a $300 stroller? My landlord just evicted us')
  expect(hardship.assistant_message.content).toMatch(/coach/i)
  expect(hardship.assistant_message.content).not.toMatch(/The \$300 purchase|Scenario only|readiness color/i)
  expect(hardship.transaction_draft).toBeNull()
  expect(hardship.mia_action_draft).toBeNull()
  for (const [width, height] of [[390, 844], [320, 568], [1366, 900]]) {
    await page.setViewportSize({ width, height })
    await capture(page, info, `live-hardship-${width}`, hardship)
  }
})

test('BOG UI household fresh setup keeps missed answers in setup and reviews every saved number', async ({ page, request }, info) => {
  test.skip(!setupUrl, 'Requires a fresh isolated e2e_participant household.')
  test.setTimeout(600_000)
  if (evidenceDir) await mkdir(evidenceDir, { recursive: true })
  const replies: unknown[] = []
  const setupHeaders = { Authorization: headers.Authorization }
  const ask = async (message: string) => {
    const reply = await send(page, message)
    replies.push(reply)
    if (evidenceDir) await writeFile(`${evidenceDir}/setup-replies-progress-${info.project.name}.json`, JSON.stringify(replies, null, 2))
    return reply
  }
  const apply = async (draftId: number) => {
    const pending = page.getByRole('button', { name: /change.*to review/ })
    if (await pending.isVisible()) await pending.click()
    const done = page.waitForResponse(response => response.url().includes(`/mia_action_drafts/${draftId}/apply`) && response.request().method() === 'POST')
    const applyButton = page.getByRole('button', { name: /^Apply (?:change|starting picture|\d+ values?)$/ })
    await expect(applyButton).toBeVisible({ timeout: 30_000 })
    await applyButton.click()
    const response = await done
    expect(response.ok(), await response.text()).toBe(true)
    await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()
    await expect(page.getByRole('textbox', { name: 'Ask Mia', exact: true })).toBeEnabled({ timeout: 30_000 })
  }
  const shots = async (name: string) => {
    for (const [width, height] of [[390, 844], [320, 568], [1366, 900]]) {
      await page.setViewportSize({ width, height })
      await capture(page, info, `setup-${name}-${width}`)
    }
    await page.setViewportSize({ width: 390, height: 844 })
  }
  await page.goto(`${setupUrl}/?pilot_e2e_role=participant&pilot_e2e_live_api=true&w20_phase=setup#Home`)
  await expect(page.getByRole('button', { name: 'Set up with Mia', exact: true })).toBeVisible({ timeout: 60_000 })
  await page.getByRole('button', { name: 'Set up with Mia', exact: true }).click()
  await expect(page.getByRole('textbox', { name: 'Ask Mia', exact: true })).toBeEnabled()
  const miss = await ask('$3,900')
  expect(miss.assistant_message.content).toContain('What would you like to call this household?')
  expect(miss.assistant_message.content).not.toMatch(/readiness/i)
  await shots('missed-name')
  const name = 'The Santos Cruz Dela Rosa extended family household of Dededo'
  const named = await ask(name)
  expect(named.mia_action_draft).toBeTruthy()
  await shots('long-name-review')
  await apply(named.mia_action_draft.id)
  const goal = await ask('Pay off Visa')
  await apply(goal.mia_action_draft.id)
  const reported = await ask('I spent $12 at Target today')
  expect(reported.transaction_draft).toBeTruthy()
  expect(reported.transaction_draft.amount_cents).toBe(1200)
  for (const message of ['What is a sinking fund?', 'My husband left me last night', 'I need to talk to someone', 'How do I contact my coach?', 'Can I afford a $300 stroller?']) {
    const unrelated = await ask(message)
    expect(unrelated.assistant_message.content).not.toMatch(/^Next setup question:/)
    expect(unrelated.mia_action_draft).toBeNull()
  }
  const unsure = await ask('I am not sure')
  expect(unsure.assistant_message.content).toContain('monthly take-home income')
  expect(unsure.assistant_message.content).not.toMatch(/readiness/i)
  const income = await ask('I take home about $4,800 a month from my job at the hospital')
  expect(income.mia_action_draft).toBeTruthy()
  const before = await request.get(`${apiUrl}/api/v1/workspace`, { headers: setupHeaders })
  expect((await before.json()).workspace.income_sources).toHaveLength(0)
  const bare = await ask('$4,800')
  expect(bare.mia_action_draft).toBeTruthy()
  await shots('income-recovered')
  await apply(bare.mia_action_draft.id)
  for (const value of ['$2,100', '$900', 'no debt payments']) {
    const answer = await ask(value)
    expect(answer.mia_action_draft).toBeTruthy()
    if (value === 'no debt payments') {
      expect(answer.assistant_message.content).toContain('$0')
      await shots('zero-debt-review')
    }
    await apply(answer.mia_action_draft.id)
  }
  await page.getByRole('link', { name: 'Home', exact: true }).click()
  await expect(page.getByText('$1,800', { exact: true }).first()).toBeVisible()
  await expect(page.getByText('Not known yet', { exact: true })).toBeVisible()
  await shots('complete-home')
  const saved = await request.get(`${apiUrl}/api/v1/workspace`, { headers: setupHeaders })
  const data = await saved.json()
  expect(data.workspace.setup_complete).toBe(true)
  expect(data.workspace.setup_values.household_name).toBe(name)
  expect(data.workspace.setup_values.primary_income).toBe(4800)
  expect(data.workspace.setup_values.debt_payment).toBe(0)
  expect(data.dashboard.month_answer.plan_left_cents).toBe(180000)
  if (evidenceDir) await writeFile(`${evidenceDir}/setup-replies-and-saved-outcomes-${info.project.name}.json`, JSON.stringify({ replies, data }, null, 2))
})

test('BOG UI missing debt minimums link opens the matching controls without confirming a value', async ({ page, request }, info) => {
  test.skip(!setupLinkUrl, 'Requires the isolated five-answer W20 household fixture.')
  test.setTimeout(120_000)
  await page.goto(`${setupLinkUrl}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Home`)
  const debt = page.getByLabel('Your month in money', { exact: true }).getByRole('button', { name: 'Add debt minimums', exact: true })
  await expect(debt).toBeVisible({ timeout: 60_000 })
  await expect(page.getByRole('button', { name: 'Set up with Mia', exact: true })).toHaveCount(0)
  for (const [width, height] of [[390, 844], [320, 568], [1366, 900]]) {
    await page.setViewportSize({ width, height })
    expect((await debt.boundingBox())?.height).toBeGreaterThanOrEqual(44)
    await capture(page, info, `setup-debt-link-${width}`)
  }
  await debt.click()
  await expect(page.getByRole('heading', { name: 'Choose the amount of detail that works for your household.', exact: true })).toBeVisible({ timeout: 30_000 })
  for (const [width, height] of [[390, 844], [320, 568], [1366, 900]]) {
    await page.setViewportSize({ width, height })
    await capture(page, info, `setup-debt-destination-${width}`)
  }
  const saved = await request.get(`${apiUrl}/api/v1/workspace`, { headers: { Authorization: headers.Authorization } })
  expect(saved.ok()).toBe(true)
  const data = await saved.json()
  expect(data.workspace.setup_complete).toBe(true)
  expect(data.workspace.setup_status.missing_fields.map((field: { key: string }) => field.key)).toEqual(['debt_payment'])
  if (evidenceDir) await writeFile(`${evidenceDir}/setup-debt-link-saved-outcome.json`, JSON.stringify(data, null, 2))
})

test('BOG UI Mia purchase keeps the household category and saves spending only after review', async ({ page, request }, info) => {
  test.skip(!purchaseConfirmUrl, 'Requires the isolated W20 household with an Everyday spending category.')
  test.setTimeout(180_000)
  const projects = ['desktop-chrome', 'tablet-768-chrome', 'tablet-1024-chrome', 'mobile-chrome', 'compact-mobile-chrome', 'mobile-webkit']
  const index = projects.indexOf(info.project.name)
  expect(index).toBeGreaterThanOrEqual(0)
  const merchant = ['Penny Cafe', 'Village Cafe', 'Corner Cafe', 'Harbor Cafe', 'School Cafe', 'Family Cafe'][index]
  const cents = 1250 + index
  const privateHeaders = { Authorization: headers.Authorization }
  const workspace = async () => {
    const response = await request.get(`${apiUrl}/api/v1/workspace`, { headers: privateHeaders })
    expect(response.ok()).toBe(true)
    return response.json()
  }
  const budget = async () => {
    const response = await request.get(`${apiUrl}/api/v1/budget`, { headers: privateHeaders })
    expect(response.ok()).toBe(true)
    return response.json()
  }
  const before = await workspace()
  const beforeBudget = await budget()
  if (info.project.name === 'desktop-chrome') await page.setViewportSize({ width: 1366, height: 900 })
  await page.goto(`${purchaseConfirmUrl}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Ask%20Mia`)
  const reply = await send(page, `I spent $${(cents / 100).toFixed(2)} at ${merchant} today`)
  expect(reply.transaction_draft.category_name).toBe('Everyday spending')
  expect(reply.assistant_message.content).toContain('Everyday spending')
  const unreviewed = await workspace()
  expect(unreviewed.dashboard.month_answer.spent_so_far_cents).toBe(before.dashboard.month_answer.spent_so_far_cents)
  const unreviewedBudget = await budget()
  expect(unreviewedBudget.annual_plan.recent_transactions).toEqual(beforeBudget.annual_plan.recent_transactions)
  await capture(page, info, 'purchase-category-before-review', { reply, before, unreviewed })
  await page.getByRole('link', { name: 'Review', exact: true }).click()
  const card = page.locator(`[data-review-item="${reply.transaction_draft.id}"]`)
  await expect(card).toContainText('Everyday spending')
  await capture(page, info, 'purchase-category-review')
  const confirmed = page.waitForResponse(response => response.url().endsWith(`/transaction_drafts/${reply.transaction_draft.id}/confirm`) && response.request().method() === 'POST')
  await card.getByRole('button', { name: /^Confirm(?: |$)/ }).click()
  expect((await confirmed).ok()).toBe(true)
  await expect(card).toHaveCount(0, { timeout: 30_000 })
  const after = await workspace()
  const afterBudget = await budget()
  expect(after.dashboard.month_answer.spent_so_far_cents).toBe((before.dashboard.month_answer.spent_so_far_cents ?? 0) + cents)
  expect(afterBudget.annual_plan.recent_transactions).toHaveLength(beforeBudget.annual_plan.recent_transactions.length + 1)
  expect(afterBudget.annual_plan.pending_transaction_drafts).toHaveLength(0)
  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()
  const saved = page.getByText(`Saved ${merchant} for $${(cents / 100).toFixed(2)} in Everyday spending. It now counts in your spending total.`, { exact: true })
  await expect(saved).toBeVisible({ timeout: 30_000 })
  await capture(page, info, 'purchase-category-saved', { before, reply, unreviewed, after, afterBudget })
})

test('BOG UI review one broad household answers and explicit category purchase preserve saved outcomes', async ({ page, request }, info) => {
  const url = process.env.HCFO_MIA_REVIEW_URL
  test.skip(!url, 'Opt-in isolated Rails fixture; model disabled.')
  test.setTimeout(300_000)
  const privateHeaders = { Authorization: headers.Authorization }
  const getWorkspace = async () => {
    const response = await request.get(`${apiUrl}/api/v1/workspace`, { headers: privateHeaders })
    expect(response.ok()).toBe(true)
    return response.json()
  }
  const before = await getWorkspace()
  await page.goto(`${url}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Ask%20Mia`)
  const replies = []
  for (const [message, expected] of [
    ['What is my budget for October?', /October 2026.*no plan|no plan.*October 2026/],
    ['How much is left in my budget for August?', /August 2026.*no plan|no plan.*August 2026/],
    ['Can I afford a $300 stroller in January?', /2027 plan is not set up/],
    ['How am I doing in January 2027?', /2027 plan is not set up/],
    ['Could I have bought a $300 stroller on October 1?', /October 2026.*no plan/],
    ['Can I afford a $300 stroller? What is a sinking fund?', /sinking fund is money/],
    ["Can I afford a $300 stroller? I haven't eaten in two days", /food.*today/],
    ["I've been skipping meals so the kids could eat", /food.*today/],
    ['Can I afford a $300 stroller? My landlord just evicted us', /coach/],
    ['Should I buy a $300 stroller?', /\$300.*\$1,105.*\$1,405/],
    ['I want to buy a $300 stroller', /\$300.*\$1,105.*\$1,405/],
    ['Can I afford a stroller?', /What does the item cost|The \$300 purchase/],
  ] as Array<[string, RegExp]>) {
    const result = await send(page, message)
    expect(result.assistant_message.content, message).toMatch(expected)
    expect(result.assistant_message.content).not.toMatch(/readiness color|Plaid-derived|liquid account picture|Scenario only|plan figure for Stroller/)
    expect(result.transaction_draft).toBeNull()
    expect(result.mia_action_draft).toBeNull()
    replies.push({ message, result })
  }
  const afterReads = await getWorkspace()
  expect(afterReads.dashboard.month_answer).toEqual(before.dashboard.month_answer)
  expect(afterReads.workspace.setup_complete).toBe(true)
  const merchant = `Village Market ${info.project.name.replaceAll('-', ' ')}`
  const purchase = await send(page, `I spent $12.50 at ${merchant} for Everyday spending today`)
  expect(purchase.transaction_draft.merchant).toBe(merchant)
  expect(purchase.transaction_draft.category_name).toBe('Everyday spending')
  const pending = await getWorkspace()
  expect(pending.dashboard.month_answer.spent_so_far_cents).toBe(before.dashboard.month_answer.spent_so_far_cents)
  await page.getByRole('link', { name: 'Review', exact: true }).click()
  const card = page.locator(`[data-review-item="${purchase.transaction_draft.id}"]`)
  const confirmed = page.waitForResponse(response => response.url().endsWith(`/transaction_drafts/${purchase.transaction_draft.id}/confirm`) && response.request().method() === 'POST')
  await card.getByRole('button', { name: /^Confirm(?: |$)/ }).click()
  expect((await confirmed).ok()).toBe(true)
  await expect(card).toHaveCount(0)
  const saved = await getWorkspace()
  expect(saved.dashboard.month_answer.spent_so_far_cents).toBe((before.dashboard.month_answer.spent_so_far_cents ?? 0) + 1250)
  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()
  for (const [width, height] of [[1366, 900], [390, 844], [320, 568]]) {
    await page.setViewportSize({ width, height })
    await capture(page, info, `review-one-saved-${width}`, { before, replies, afterReads, purchase, pending, saved })
  }
})
