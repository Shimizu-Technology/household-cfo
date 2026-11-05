import { expect, test, type Page, type TestInfo } from '@playwright/test'
import { mkdir, writeFile } from 'node:fs/promises'

// Synthetic W20 household: November join, reviewed October spending $2,254.65,
// income $4,500, costs $3,000, debt minimums $95, no entered account balances.
const liveUrl = process.env.HCFO_MIA_FRESH_LIVE_URL
const apiUrl = process.env.HCFO_MIA_FRESH_API_URL ?? 'http://127.0.0.1:3222'
const evidenceDir = process.env.HCFO_MIA_FRESH_EVIDENCE_DIR
const setupUrl = process.env.HCFO_MIA_SETUP_LIVE_URL
const modelUrl = process.env.HCFO_MIA_TWO_MODEL_CALLS_URL
const headers = { Authorization: 'Bearer test_token:e2e_participant:participant@pilot.test:Test:Participant', 'X-Cohort-Id': '1' }

async function send(page: Page, message: string) {
  const composer = page.getByRole('textbox', { name: 'Ask Mia', exact: true })
  await expect(composer).toBeEnabled({ timeout: 30_000 })
  await composer.fill(message)
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
  await page.getByRole('button', { name: 'Add account balances', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'Your household money', exact: true })).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Keep one approved balance for each household asset.', exact: true })).toBeVisible()
  await capture(page, info, 'cushion-link-accounts')
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
  test.skip(!modelUrl, 'Opt-in only: uses the worker’s two remaining live model requests.')
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
  const food = await send(page, 'I skipped meals this week so the kids could eat')
  expect(food.assistant_message.content).toMatch(/food|meals|eat/i)
  expect(food.assistant_message.content).toContain('coach')
  expect(food.assistant_message.content).toContain('today')
  expect(food.assistant_message.content).not.toMatch(/which bill|proud|great job|discipline/i)
  for (const [width, height] of [[390, 844], [320, 568], [1366, 900]]) {
    await page.setViewportSize({ width, height })
    await capture(page, info, `live-food-${width}`, food)
  }
})

test('BOG UI household fresh setup keeps missed answers in setup and reviews every saved number', async ({ page, request }, info) => {
  test.skip(!setupUrl, 'Requires a fresh isolated e2e_participant household.')
  test.setTimeout(600_000)
  const replies: unknown[] = []
  const setupHeaders = { Authorization: headers.Authorization }
  const ask = async (message: string) => {
    const reply = await send(page, message)
    replies.push(reply)
    if (evidenceDir) await writeFile(`${evidenceDir}/setup-replies-progress.json`, JSON.stringify(replies, null, 2))
    return reply
  }
  const apply = async (draftId: number) => {
    const pending = page.getByRole('button', { name: /change.*to review/ })
    if (await pending.isVisible()) await pending.click()
    const done = page.waitForResponse(response => response.url().includes(`/mia_action_drafts/${draftId}/apply`) && response.request().method() === 'POST')
    const applyButton = page.getByRole('button', { name: /^Apply (?:change|\d+ values?)$/ })
    await expect(applyButton).toBeVisible({ timeout: 30_000 })
    await applyButton.click()
    expect((await done).ok()).toBe(true)
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
  const name = 'The Santos Cruz Dela Rosa extended household in Dededo with Nana and the grandchildren'
  const named = await ask(name)
  expect(named.mia_action_draft).toBeTruthy()
  await shots('long-name-review')
  await apply(named.mia_action_draft.id)
  const goal = await ask('Pay off Visa')
  await apply(goal.mia_action_draft.id)
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
  if (evidenceDir) await writeFile(`${evidenceDir}/setup-replies-and-saved-outcomes.json`, JSON.stringify({ replies, data }, null, 2))
})
