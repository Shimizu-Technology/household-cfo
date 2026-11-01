import { expect, test } from '@playwright/test'
import { writeFileSync } from 'node:fs'

// Opt-in acceptance against the worker's isolated Rails API. No model calls or
// mocked financial responses; normal CI runs the existing mocked review specs.
test('mobile Ask Mia household coaching and inline new category', async ({ page, request }, testInfo) => {
  test.skip(process.env.HCFO_W1_LIVE_API !== '1', 'Requires the isolated W1 synthetic API fixture')
  test.setTimeout(600_000)
  const token = 'test_token:e2e_participant:w1-participant@example.invalid:Ana:Test'
  const headers = { Authorization: `Bearer ${token}` }
  const api = 'http://127.0.0.1:3201/api/v1'
  const transcripts: Array<{ prompt: string; reply: string; month_answer?: unknown }> = []
  const evidence = process.env.HCFO_W1_EVIDENCE!
  const label = testInfo.project.name
  const before = await (await request.get(`${api}/workspace`, { headers })).json()
  const beforePlan = before.budget.annual_plan
  const currentMonth = new Date().getMonth()
  await page.goto('/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Ask%20Mia')
  const composer = page.getByRole('textbox', { name: 'Ask Mia', exact: true })
  await expect(composer).toBeVisible({ timeout: 90_000 })
  await page.screenshot({ path: `${evidence}/${label}-empty.png`, fullPage: true })

  async function ask(prompt: string, name: string, expected: RegExp) {
    await composer.fill(prompt)
    const reply = page.waitForResponse((response) => response.url().includes('/api/v1/mia/messages') && response.request().method() === 'POST', { timeout: 90_000 })
    await page.getByRole('button', { name: 'Send message to Mia', exact: true }).click()
    const result = await reply
    expect(result.status()).toBe(201)
    const body = await result.json()
    expect(body.assistant_message.content).toMatch(expected)
    transcripts.push({ prompt, reply: body.assistant_message.content, month_answer: body.month_answer })
    writeFileSync(`${evidence}/${label}-transcript.json`, JSON.stringify(transcripts, null, 2))
    await expect(composer).toBeEnabled({ timeout: 90_000 })
    await page.getByText(body.assistant_message.content, { exact: true }).last().scrollIntoViewIfNeeded().catch(() => {})
    await page.screenshot({ path: `${evidence}/${label}-${name}.png`, fullPage: true })
    return body
  }

  await ask("I'm thinking to buy a purse at Ross for $60", 'ross-purse', /pause|fund/i)
  await ask('I stayed under my grocery budget for the whole week!', 'win', /kept|within/i)
  await ask("I went to Ross again today. That's the third time this month.", 'ross-again', /Ross|repeat/i)
  await ask("I'm so stressed about money this week.", 'stress', /heavy week|bill/i)
  const month = await ask('How am I doing this month?', 'month', /money in.*planned out/i)
  expect(month.month_answer.plan_left_cents).toBe(month.month_answer.money_in_cents - month.month_answer.planned_out_cents)
  // Each project changes the same synthetic fixture to a distinct amount so
  // later projects exercise an actual change rather than an already-saved value.
  const requestedSalary = 6400 + testInfo.config.projects.findIndex((project) => project.name === label)
  const salaryAmount = Number(beforePlan.monthly_income[beforePlan.months[currentMonth].id]) === requestedSalary ? requestedSalary + 100 : requestedSalary
  const salary = await ask(`My salary is $${salaryAmount.toLocaleString('en-US')} now`, 'salary', /review|month|income/i)
  expect(JSON.stringify(salary.mia_action_draft)).toContain(`${new Date().getFullYear()}-${String(new Date().getMonth() + 1).padStart(2, '0')}-01`)
  const salaryCard = page.locator('.mia-action-draft-card').filter({ hasText: salary.mia_action_draft.title }).last()
  await salaryCard.getByRole('button', { name: 'Apply reviewed change', exact: true }).click()
  await expect(salaryCard).toHaveCount(0, { timeout: 90_000 })
  await page.screenshot({ path: `${evidence}/${label}-salary-applied.png`, fullPage: true })
  const afterSalary = await (await request.get(`${api}/workspace`, { headers })).json()
  const afterPlan = afterSalary.budget.annual_plan
  for (const period of beforePlan.months.slice(0, currentMonth)) {
    expect(afterPlan.monthly_income[period.id]).toBe(beforePlan.monthly_income[period.id])
  }
  expect(afterPlan.monthly_income[afterPlan.months[currentMonth].id]).toBe(salaryAmount)
  const purchase = await ask('Spent $12 at Payless on cigarettes. Put it in a new Cigarettes category.', 'category-chat', /Payless|review/i)
  const id = purchase.transaction_draft.id
  const card = page.locator(`[data-review-item="${id}"]`)
  await card.getByRole('button', { name: /^Edit Payless/ }).click()
  await card.getByRole('combobox', { name: 'Category', exact: true }).selectOption('new')
  const name = `Cigarettes ${label}`
  await card.getByRole('textbox', { name: 'New category name', exact: true }).fill(name)
  await card.getByRole('textbox', { name: 'New category name', exact: true }).evaluate((input) => input.scrollIntoView({ block: 'center' }))
  await page.screenshot({ path: `${evidence}/${label}-category-edit.png`, fullPage: true })
  await card.getByRole('button', { name: 'Save draft', exact: true }).click()
  const confirm = card.getByRole('button', { name: /^Confirm Payless/ })
  await expect(confirm).toBeEnabled({ timeout: 90_000 })
  await confirm.click()
  await expect(card).toHaveCount(0, { timeout: 90_000 })
  await page.screenshot({ path: `${evidence}/${label}-category-confirmed.png`, fullPage: true })
  const incurred = await ask('I went to Ross again and spent $60 today', 'ross-purchase', /Ross|review/i)
  expect(incurred.transaction_draft.merchant).toBe('Ross')
  expect(incurred.transaction_draft.amount_cents).toBe(6000)
  await ask('I spent money at Review Store today', 'purchase-question', /how much|amount/i)
  const dated = await ask('It was $60 on October 1, 2026', 'purchase-date', /Review Store|review/i)
  expect(dated.transaction_draft.occurred_on).toBe('2026-10-01')
  const namedMonth = await ask('How am I doing in September 2026?', 'named-month', /September 2026/)
  expect(namedMonth.month_answer.year).toBe(2026)
  expect(namedMonth.month_answer.month).toBe(9)
  const workspace = await request.get(`${api}/workspace`, { headers })
  expect(workspace.ok()).toBe(true)
  const saved = await workspace.json()
  for (const turn of transcripts) {
    expect(saved.mia.messages.some((message: { role: string; content: string }) => message.role === 'user' && message.content === turn.prompt)).toBe(true)
  }
  const category = saved.budget.annual_plan.rows.find((row: { name: string }) => row.name === name)
  expect(category).toBeTruthy()
  expect(saved.budget.annual_plan.recent_transactions.some((transaction: { merchant: string; amount: number; categories: string[] }) => transaction.merchant === 'Payless' && Number(transaction.amount) === 12 && transaction.categories.includes(name))).toBe(true)
  const confirmation = saved.mia.messages.find((message: { role: string; content: string }) => message.role === 'assistant' && message.content.includes('Confirmed Payless') && message.content.includes(name))
  expect(confirmation).toBeTruthy()
  expect(confirmation.content).not.toContain('Uncategorized')
  await testInfo.attach('transcript', { body: JSON.stringify(transcripts, null, 2), contentType: 'application/json' })
  await testInfo.attach('saved-workspace', { body: JSON.stringify(saved, null, 2), contentType: 'application/json' })
  writeFileSync(`${evidence}/${label}-transcript.json`, JSON.stringify(transcripts, null, 2))
  writeFileSync(`${evidence}/${label}-saved-workspace.json`, JSON.stringify(saved, null, 2))
  writeFileSync(`${evidence}/${label}-salary-readback.json`, JSON.stringify({ before: beforePlan.monthly_income, after: afterPlan.monthly_income }, null, 2))
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})
