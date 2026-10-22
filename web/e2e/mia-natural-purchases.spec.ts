import { expect, test, type APIRequestContext, type Page, type TestInfo } from '@playwright/test'
import { mkdir, writeFile } from 'node:fs/promises'

// Opt-in real-stack acceptance. Use a dedicated test DB, the e2e participant
// (id 901), one enrolled challenge and one ordinary household program.
const liveUrl = process.env.HCFO_PURCHASE_LIVE_URL
const apiUrl = process.env.HCFO_PURCHASE_API_URL ?? 'http://127.0.0.1:3192'
const challengeId = Number(process.env.HCFO_PURCHASE_CHALLENGE_ID ?? 2001)
const householdId = Number(process.env.HCFO_PURCHASE_HOUSEHOLD_ID ?? 2002)
const evidenceDir = process.env.HCFO_PURCHASE_EVIDENCE_DIR
const framing = "For today's check-in, I spent $12.34 at Payless on groceries today and bought nothing else. Please prepare one check-in card for me to review. Don't save these purchases until I approve."
const several = 'Yesterday I spent eighteen dollars and forty-seven cents at Payless on groceries and bought a $5 coffee at Starbucks this morning and bought nothing else.'
type Purchase = { amount_cents: number; merchant: string; purchased_on: string }
type Draft = { id: number; merchant: string; amount_cents: number; occurred_on: string; status: string; category_name: string }
type Daily = { calendar: { local_today: string }; day: { reported_spend_cents: number } }
type SavedPurchases = { records: { id: number; current_version: Purchase }[] }
type Budget = { annual_plan: { pending_transaction_drafts: Draft[] } }
type Spending = { spending_report: { transactions: { id: number; amount: number; merchant: string }[] } }

function headers(cohort: number) {
  return { Authorization: 'Bearer test_token:e2e_participant:participant@pilot.test:Test:Participant', 'X-Cohort-Id': String(cohort) }
}
async function read<T>(request: APIRequestContext, path: string, cohort: number): Promise<T> {
  const response = await request.get(`${apiUrl}/api/v1/${path}`, { headers: headers(cohort) })
  expect(response.ok(), `${path}: ${response.status()} ${await response.text()}`).toBe(true)
  return response.json() as Promise<T>
}
async function openMia(page: Page, cohort: number, info: TestInfo) {
  if (info.project.name === 'desktop-chrome') await page.setViewportSize({ width: 1366, height: 900 })
  await page.addInitScript((id) => localStorage.setItem('household-cfo:participant-program:v2:e2e_participant:901', String(id)), cohort)
  await page.goto(`${liveUrl}/?pilot_e2e_role=participant&pilot_e2e_live_api=true`)
  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()
  await expect(page.getByRole('textbox', { name: 'Ask Mia', exact: true })).toBeEnabled()
}
async function send(page: Page, message: string) {
  const composer = page.getByRole('textbox', { name: 'Ask Mia', exact: true })
  await expect(composer).toBeEnabled()
  await composer.fill(message)
  const response = page.waitForResponse((reply) => reply.url().includes('/api/v1/mia/messages') && reply.request().method() === 'POST')
  const button = page.getByRole('button', { name: 'Send message to Mia', exact: true })
  await expect(button).toBeEnabled()
  await button.click()
  const result = await response
  expect(result.status()).toBe(201)
  return result.json()
}
async function evidence(page: Page, info: TestInfo, name: string, data: unknown) {
  const base = `${info.project.name}-${name}`
  const path = info.outputPath(`${base}.png`)
  await page.screenshot({ path, fullPage: true })
  await info.attach(base, { path, contentType: 'image/png' })
  if (evidenceDir) {
    await mkdir(`${evidenceDir}/shots`, { recursive: true })
    await page.screenshot({ path: `${evidenceDir}/shots/${base}.png`, fullPage: true })
    await writeFile(`${evidenceDir}/${base}.json`, JSON.stringify(data, null, 2))
  }
}
function previousDay(today: string) {
  const date = new Date(`${today}T12:00:00Z`)
  date.setUTCDate(date.getUTCDate() - 1)
  return date.toISOString().slice(0, 10)
}

test.describe('BOG UI natural Mia purchases against real Rails', () => {
  test.skip(!liveUrl, 'Set HCFO_PURCHASE_LIVE_URL for dedicated real-stack acceptance; no mocked financial responses.')
  test.setTimeout(180_000)
  test.beforeEach(() => { test.setTimeout(180_000) })

  test('the framed QA check-in is exactly one unreviewed card and never saves on send', async ({ page, request }, info) => {
    const before = await read<SavedPurchases>(request, 'savings_challenge/daily/records?collection=purchases', challengeId)
    const daily = await read<Daily>(request, 'savings_challenge/daily', challengeId)
    await openMia(page, challengeId, info)
    const reply = await send(page, framing)
    expect(reply.savings_intake.purchases).toEqual([{ amount_cents: 1234, merchant: 'Payless', purchased_on: daily.calendar.local_today }])
    const card = page.getByRole('region', { name: 'Your check-in', exact: true })
    await expect(card).toHaveCount(1)
    await expect(card.getByLabel('Amount for Payless', { exact: true })).toHaveValue('12.34')
    await expect(card.locator('input[data-row-amount]')).toHaveCount(1)
    const after = await read<SavedPurchases>(request, 'savings_challenge/daily/records?collection=purchases', challengeId)
    expect(after.records).toEqual(before.records)
    await evidence(page, info, 'savings-framed-unapproved', { before, reply, after })
  })

  test('spoken cents and a coffee share one card with separate dates and save only after approval', async ({ page, request }, info) => {
    const before = await read<SavedPurchases>(request, 'savings_challenge/daily/records?collection=purchases', challengeId)
    const daily = await read<Daily>(request, 'savings_challenge/daily', challengeId)
    const expected = [
      { amount_cents: 1847, merchant: 'Payless', purchased_on: previousDay(daily.calendar.local_today) },
      { amount_cents: 500, merchant: 'Starbucks', purchased_on: daily.calendar.local_today },
    ]
    await openMia(page, challengeId, info)
    const reply = await send(page, several)
    expect(reply.savings_intake.purchases).toEqual(expected)
    const card = page.getByRole('region', { name: 'Your check-in', exact: true })
    await expect(card).toHaveCount(1)
    await expect(card.locator('input[data-row-amount]')).toHaveCount(2)
    await expect(card.getByLabel('Amount for Payless', { exact: true })).toHaveValue('18.47')
    await expect(card.getByLabel('Amount for Starbucks', { exact: true })).toHaveValue('5.00')
    const unapproved = await read<SavedPurchases>(request, 'savings_challenge/daily/records?collection=purchases', challengeId)
    expect(unapproved.records).toEqual(before.records)
    await evidence(page, info, 'savings-multiple-unapproved', { before, reply, unapproved })
    await card.getByRole('button', { name: 'Save', exact: true }).click()
    await expect(card.getByRole('heading', { name: 'Saved', exact: true })).toBeVisible({ timeout: 45_000 })
    const after = await read<SavedPurchases>(request, 'savings_challenge/daily/records?collection=purchases', challengeId)
    const added = after.records.filter((row) => !before.records.some((old) => old.id === row.id))
    expect(added.map((row) => ({ amount_cents: row.current_version.amount_cents, merchant: row.current_version.merchant, purchased_on: row.current_version.purchased_on }))).toEqual(expected)
    await evidence(page, info, 'savings-multiple-approved', { before, reply, after, added })
  })

  test('household multiple purchases keep exact separate pending drafts and categories until confirmed', async ({ page, request }, info) => {
    const year = new Date().getFullYear()
    const before = await read<Budget>(request, `budget?year=${year}`, householdId)
    const daily = await read<Daily>(request, 'savings_challenge/daily', challengeId)
    const start = `${daily.calendar.local_today.slice(0, 7)}-01`
    const spendingPath = `spending_report?start_on=${start}&end_on=${daily.calendar.local_today}`
    const spentBefore = await read<Spending>(request, spendingPath, householdId)
    await openMia(page, householdId, info)
    const reply = await send(page, several)
    const pending = await read<Budget>(request, `budget?year=${year}`, householdId)
    const added = pending.annual_plan.pending_transaction_drafts.filter((row) => !before.annual_plan.pending_transaction_drafts.some((old) => old.id === row.id)).sort((a, b) => a.id - b.id)
    expect(added.map((row) => [row.amount_cents, row.merchant, row.occurred_on, row.status, row.category_name])).toEqual([
      [1847, 'Payless', previousDay(daily.calendar.local_today), 'pending', 'Groceries'],
      [500, 'Starbucks', daily.calendar.local_today, 'pending', 'Dining out'],
    ])
    const pageSize = page.getByRole('combobox', { name: 'Show', exact: true })
    if (await pageSize.count()) await pageSize.selectOption('25')
    for (const draft of added) {
      expect(reply.assistant_message.content).toContain(draft.merchant)
      await expect(page.locator(`[data-review-item="${draft.id}"]`)).toHaveCount(1)
    }
    const unapproved = await read<Spending>(request, spendingPath, householdId)
    expect(unapproved.spending_report.transactions).toEqual(spentBefore.spending_report.transactions)
    await evidence(page, info, 'household-multiple-unapproved', { before, reply, added, spentBefore, unapproved })
    for (const draft of added) {
      const button = page.locator(`[data-review-item="${draft.id}"]`).getByRole('button', { name: /^Confirm / })
      await expect(button).toBeEnabled()
      await button.click()
      await expect(page.locator(`[data-review-item="${draft.id}"]`)).toHaveCount(0, { timeout: 45_000 })
    }
    const after = await read<Spending>(request, spendingPath, householdId)
    const recorded = after.spending_report.transactions.filter((row) => !spentBefore.spending_report.transactions.some((old) => old.id === row.id))
    expect(recorded.map((row) => [Math.round(row.amount * 100), row.merchant]).sort()).toEqual([[1847, 'Payless'], [500, 'Starbucks']].sort())
    await evidence(page, info, 'household-multiple-confirmed', { after, recorded })
  })

  test('household framed QA wording creates exactly one pending purchase and no actual spending', async ({ page, request }, info) => {
    const year = new Date().getFullYear()
    const before = await read<Budget>(request, `budget?year=${year}`, householdId)
    const daily = await read<Daily>(request, 'savings_challenge/daily', challengeId)
    const spendingPath = `spending_report?start_on=${daily.calendar.local_today.slice(0, 7)}-01&end_on=${daily.calendar.local_today}`
    const spentBefore = await read<Spending>(request, spendingPath, householdId)
    await openMia(page, householdId, info)
    const reply = await send(page, framing)
    const after = await read<Budget>(request, `budget?year=${year}`, householdId)
    const added = after.annual_plan.pending_transaction_drafts.filter((row) => !before.annual_plan.pending_transaction_drafts.some((old) => old.id === row.id))
    expect(added.map((row) => [row.amount_cents, row.merchant, row.category_name, row.status])).toEqual([[1234, 'Payless', 'Groceries', 'pending']])
    expect(reply.assistant_message.content).toContain('Payless')
    const spentAfter = await read<Spending>(request, spendingPath, householdId)
    expect(spentAfter.spending_report.transactions).toEqual(spentBefore.spending_report.transactions)
    await evidence(page, info, 'household-framed-unapproved', { before, reply, added, spentBefore, spentAfter })
  })

  test('safety savings goals investments and no-spend retain their distinct paths', async ({ page, request }, info) => {
    const before = await read<SavedPurchases>(request, 'savings_challenge/daily/records?collection=purchases', challengeId)
    await openMia(page, challengeId, info)
    const replies = []
    for (const message of ['Change my goal to $300', 'should I change my goal?', 'saved $50 today', 'I bought $50 of bitcoin at Coinbase', 'I feel hopeless and want to die']) {
      const reply = await send(page, message)
      replies.push(reply)
      expect(reply.savings_intake?.kind).not.toBe('daily_report')
      await expect(page.getByRole('region', { name: 'Your check-in', exact: true })).toHaveCount(0)
    }
    expect(replies[2].savings_intake.kind).toBe('contribution')
    expect(replies[4].assistant_message.safety_reply).toBe(true)
    const noSpend = await send(page, 'No spending today')
    expect(noSpend.savings_intake).toMatchObject({ no_spend: true, purchases: [], counted: false })
    await expect(page.getByRole('region', { name: 'Your check-in', exact: true })).toHaveCount(1)
    const after = await read<SavedPurchases>(request, 'savings_challenge/daily/records?collection=purchases', challengeId)
    expect(after.records).toEqual(before.records)
    await evidence(page, info, 'savings-guards', { before, replies, noSpend, after })
  })
})
