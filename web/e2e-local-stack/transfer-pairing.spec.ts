import path from 'node:path'
import { mkdir } from 'node:fs/promises'
import { API, api, expect, openSection, signIn, test } from './stack'

const checking = 'Date,Account,Description,Withdrawal,Deposit,Status\n2026-07-07,Talun Checking ****7711,Zelle to Talun savings ending 4412,250.00,,Posted\n2026-07-08,Talun Checking ****7711,Zelle to Lina Talun,35.00,,Posted\n2026-07-09,Talun Checking ****7711,Venmo to Talun wallet,15.00,,Posted\n'
const savings = 'Date,Account,Description,Withdrawal,Deposit,Status\n2026-07-08,Talun Savings ****4412,Transfer from Talun checking ending 7711,,250.00,Posted\n'

test('own-account transfers pair and person payments change only reviewed spending @saves', async ({ page }) => {
  await signIn(page, 'participant')
  await openSection(page, 'Statements')
  const review = page.getByRole('region', { name: 'Statement review' })
  async function upload(name: string, contents: string) {
    await page.locator('input[type=file]').first().setInputFiles({ name, mimeType: 'text/csv', buffer: Buffer.from(contents) })
    await expect(review.getByRole('button', { name: 'Choose account', exact: true })).toBeVisible({ timeout: 60_000 })
    await review.getByRole('button', { name: 'Choose account', exact: true }).click()
    const account = page.getByRole('dialog', { name: 'Your account', exact: true })
    const choices = account.getByRole('combobox', { name: 'Account', exact: true })
    if (await choices.count()) await choices.selectOption('new')
    await account.getByRole('combobox', { name: 'Type', exact: true }).selectOption('asset')
    await account.getByRole('button', { name: 'Save', exact: true }).click()
    await expect(account).toHaveCount(0)
  }
  async function evidence(name: string) {
    for (const [label, width, height] of [['desktop', 1366, 900], ['phone', 390, 844], ['compact', 320, 844]] as const) {
      await page.setViewportSize({ width, height })
      await review.locator('.statement-exceptions').scrollIntoViewIfNeeded()
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
      const buttons = await review.locator('.statement-exceptions .statement-answers button').evaluateAll(nodes => nodes.map(node => ({ width: node.getBoundingClientRect().width, height: node.getBoundingClientRect().height })))
      expect(buttons.every(button => button.height >= 44)).toBe(true)
      if (width <= 390) expect(buttons.every(button => button.width >= width - 40)).toBe(true)
      if (process.env.HCFO_B7_EVIDENCE_DIR) {
        await mkdir(process.env.HCFO_B7_EVIDENCE_DIR, { recursive: true })
        await page.screenshot({ path: path.join(process.env.HCFO_B7_EVIDENCE_DIR, `${label}-${name}-final.png`), scale: 'css' })
      }
    }
  }
  await upload('talun-checking.csv', checking)
  await expect(review.getByText('Your own account or someone else?', { exact: true })).toHaveCount(3)
  await upload('talun-savings.csv', savings)
  const pair = review.getByRole('button', { name: /^Yes, pair them/ })
  await expect(pair).toBeEnabled()
  await evidence('pair')
  await pair.click()
  await expect(review.getByText('All 1 line is saved.', { exact: true })).toBeVisible()
  const unpair = review.getByRole('button', { name: 'Unpair these lines', exact: true })
  await expect(unpair).toBeEnabled()
  await unpair.click()
  await expect(unpair).toHaveCount(0)
  await page.getByRole('button', { name: /^talun-checking.csv Statement/ }).click()
  await expect(review.getByText('Your own account or someone else?', { exact: true })).toHaveCount(3)
  await evidence('unpaired-person-question')
  await review.getByRole('button', { name: 'Your own account: Zelle to Talun savings ending 4412', exact: true }).click()
  await evidence('person-question')
  await review.getByRole('button', { name: 'Someone else: Zelle to Lina Talun', exact: true }).click()
  await expect(review.getByText('Your own account or someone else?', { exact: true })).toHaveCount(1)
  await review.getByRole('button', { name: 'Your own account: Venmo to Talun wallet', exact: true }).click()
  await expect(review.getByText('All 3 lines are saved.', { exact: true })).toBeVisible()
  const report = await api<{ spending_report: { totals: { actual: number; pending: number }; categories: Array<{ name: string; actual: number }> } }>('participant', '/api/v1/spending_report?start_on=2026-07-01&end_on=2026-07-31')
  expect(report.spending_report.totals).toMatchObject({ actual: 35, pending: 0 })
  expect(report.spending_report.categories.find(row => row.name === 'Family support')?.actual).toBe(35)
  await page.setViewportSize({ width: 1366, height: 900 })
  await openSection(page, 'Ask Mia')
  await page.getByRole('textbox', { name: 'Ask Mia', exact: true }).fill('How much did I spend in July 2026?')
  await page.getByRole('button', { name: 'Send message to Mia', exact: true }).click()
  await expect(page.getByText(/From your approved purchases, you spent \$35 in July 2026/)).toBeVisible({ timeout: 30_000 })
})

test('merchant categories, card payments and logged person purchases keep their own questions @saves', async ({ page, request }) => {
  const imports = await api<{ document_imports: Array<{ filename: string }> }>('participant', '/api/v1/document_imports')
  const resume = imports.document_imports.some(row => row.filename === 'review-regressions.csv')
  if (!resume) {
    const budget = await api<{ annual_plan: { rows: Array<{ id: number; name: string }> } }>('participant', '/api/v1/budget?year=2026')
    const category = budget.annual_plan.rows.find(row => row.name === 'Flexible spending')!
    const headers = { Authorization: 'Bearer test_token:e2e_participant:participant@pilot.test:Test:Participant', 'Idempotency-Key': crypto.randomUUID() }
    const created = await request.post(`${API}/api/v1/transaction_drafts`, { headers, data: { transaction_draft: { occurred_on: '2026-10-03', merchant: 'Venmo Ana Cruz', amount: 40, budget_category_id: category.id } } })
    expect(created.ok()).toBe(true)
    const draft = (await created.json()).transaction_draft
    const confirmed = await request.post(`${API}/api/v1/transaction_drafts/${draft.id}/confirm`, { headers: { ...headers, 'Idempotency-Key': crypto.randomUUID() }, data: { transaction_draft: {} } })
    expect(confirmed.ok()).toBe(true)
  }
  await signIn(page, 'participant')
  await openSection(page, 'Statements')
  const review = page.getByRole('region', { name: 'Statement review' })
  const csv = 'Date,Account,Description,Withdrawal,Deposit,Status\n2026-10-03,Talun Review Checking ****4427,PAYPAL *EBAY.COM,45.99,,Posted\n2026-10-03,Talun Review Checking ****4427,PAYPAL *NETFLIX.COM,19.99,,Posted\n2026-10-03,Talun Review Checking ****4427,Payment to Guam Power Authority,75.00,,Posted\n2026-10-03,Talun Review Checking ****4427,Payment to Chase card ending 1234,500.00,,Posted\n2026-10-03,Talun Review Checking ****4427,VENMO *ANA CRUZ,40.00,,Posted\n'
  if (resume) {
    await page.getByRole('button', { name: /^review-regressions.csv Statement/ }).click()
  } else {
    await page.locator('input[type=file]').first().setInputFiles({ name: 'review-regressions.csv', mimeType: 'text/csv', buffer: Buffer.from(csv) })
    await expect(review.getByRole('button', { name: 'Choose account', exact: true })).toBeVisible({ timeout: 60_000 })
    await review.getByRole('button', { name: 'Choose account', exact: true }).click()
    const account = page.getByRole('dialog', { name: 'Your account', exact: true })
    const choices = account.getByRole('combobox', { name: 'Account', exact: true })
    if (await choices.count()) await choices.selectOption('new')
    await account.getByRole('combobox', { name: 'Type', exact: true }).selectOption('asset')
    await account.getByRole('button', { name: 'Save', exact: true }).click()
    await expect(account).toHaveCount(0)
  }
  for (const width of [1366, 390]) {
    await page.setViewportSize({ width, height: 900 })
    await expect(review.getByText('Your own account or someone else?', { exact: true })).toHaveCount(0)
    await expect(review.getByText('Is this a payment on your own card or loan?', { exact: true })).toBeVisible()
    await expect(review.getByRole('button', { name: /^Same purchase: VENMO/ })).toBeVisible()
    await review.locator('.statement-exceptions').scrollIntoViewIfNeeded()
    if (process.env.HCFO_B7_EVIDENCE_DIR) await page.screenshot({ path: path.join(process.env.HCFO_B7_EVIDENCE_DIR, `${width}-merchant-card-purchase-questions.png`) })
  }
  await review.getByText('See all 5 lines', { exact: true }).click()
  for (const merchant of ['PAYPAL *EBAY.COM', 'PAYPAL *NETFLIX.COM', 'Payment to Guam Power Authority']) {
    await review.locator('table').getByRole('button', { name: merchant, exact: true }).click()
    const sheet = page.getByRole('dialog', { name: merchant, exact: true })
    await sheet.getByLabel('What was this?').selectOption('spending')
    await sheet.getByRole('combobox', { name: /^Category/ }).selectOption({ label: 'Flexible spending' })
    await sheet.getByRole('button', { name: 'Save', exact: true }).click()
    await expect(sheet).toHaveCount(0)
  }
  await review.getByRole('button', { name: /^Yes: Payment to Chase card/ }).click()
  await review.getByRole('button', { name: /^Same purchase: VENMO/ }).click()
  await expect(review.getByText('All 5 lines are saved.', { exact: true })).toBeVisible()
  const report = await api<{ spending_report: { totals: { actual: number }; categories: Array<{ name: string; actual: number }> } }>('participant', '/api/v1/spending_report?start_on=2026-10-01&end_on=2026-10-31')
  expect(report.spending_report.totals.actual).toBe(180.98)
  expect(report.spending_report.categories.find(row => row.name === 'Flexible spending')?.actual).toBe(180.98)
  for (const width of [1366, 390]) {
    await page.setViewportSize({ width, height: 900 })
    await review.locator('.statement-summary-line').scrollIntoViewIfNeeded()
    if (process.env.HCFO_B7_EVIDENCE_DIR) await page.screenshot({ path: path.join(process.env.HCFO_B7_EVIDENCE_DIR, `${width}-merchant-card-purchase-saved.png`) })
  }
})
