import path from 'node:path'
import { mkdir } from 'node:fs/promises'
import { api, expect, openSection, signIn, test } from './stack'

const checking = 'Date,Account,Description,Withdrawal,Deposit,Status\n2026-07-07,Talun Checking ****7711,Transfer to Talun savings ending 4412,250.00,,Posted\n2026-07-08,Talun Checking ****7711,Zelle to Lina Talun,35.00,,Posted\n2026-07-09,Talun Checking ****7711,Venmo to Talun wallet,15.00,,Posted\n'
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
  await expect(review.getByText('Your own account or someone else?', { exact: true })).toHaveCount(2)
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
