import path from 'node:path'
import { api, expect, openSection, signIn, test } from './stack'

test('one store answer spans statements and one file answer excludes only approved copies @saves', async ({ page }) => {
  await signIn(page, 'participant')
  await openSection(page, 'Statements')
  const review = page.getByRole('region', { name: 'Statement review' })
  const header = 'Date,Account,Description,Withdrawal,Deposit,Status\n'
  const rows = ['2026-09-03,Talun C4 ****6639,Island Demo Mart,12.00,,Posted\n', '2026-09-04,Talun C4 ****6639,Island Demo Mart,18.00,,Posted\n']
  async function upload(name: string, contents: string, first = false) {
    await page.locator('input[type=file]').first().setInputFiles({ name, mimeType: 'text/csv', buffer: Buffer.from(contents) })
    await expect(review.getByRole('button', { name: 'Choose account', exact: true })).toBeVisible({ timeout: 60_000 })
    await review.getByRole('button', { name: 'Choose account', exact: true }).click()
    const account = page.getByRole('dialog', { name: 'Your account', exact: true })
    const choices = account.getByRole('combobox', { name: 'Account', exact: true })
    if (await choices.count()) {
      if (first) await choices.selectOption('new')
      else {
        const option = choices.locator('option').filter({ hasText: '6639' }).first()
        await choices.selectOption(await option.getAttribute('value') ?? '')
      }
    }
    const type = account.getByRole('combobox', { name: 'Type', exact: true })
    if (await type.count()) await type.selectOption('asset')
    await account.getByRole('button', { name: 'Save', exact: true }).click()
    await expect(account).toHaveCount(0)
  }
  await upload('c4-first.csv', header + rows.join(''), true)
  await upload('c4-second.csv', header + rows.join('').replaceAll('09-03', '09-13').replaceAll('09-04', '09-14'))
  await expect(review.getByText('4 lines across your statements. What are these for?')).toBeVisible()
  await review.getByRole('combobox', { name: 'Category for Island Demo Mart', exact: true }).selectOption({ label: 'Flexible spending' })
  await expect(review.getByText('All 2 lines are saved.')).toBeVisible()
  const imports = await api<{ document_imports: Array<{ filename: string; statement_review?: { done: number } }> }>('participant', '/api/v1/document_imports')
  expect(imports.document_imports.filter(file => file.filename.startsWith('c4-')).map(file => file.statement_review?.done)).toEqual([2, 2])
  await upload('c4-copies.csv', header + [...rows].reverse().join(''))
  await expect(review.getByText('2 lines in this file repeat statements you already approved. Leave them all out?')).toBeVisible()
  for (const width of [1366, 390, 320]) {
    await page.setViewportSize({ width, height: 900 })
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    if (process.env.HCFO_B7_EVIDENCE_DIR) await page.screenshot({ path: path.join(process.env.HCFO_B7_EVIDENCE_DIR, `c4-repeats-${width}.png`), fullPage: true })
  }
  const beforeCopies = await api<{ spending_report: { totals: { actual: number } } }>('participant', '/api/v1/spending_report?start_on=2026-09-01&end_on=2026-09-30')
  expect(beforeCopies.spending_report.totals.actual).toBe(60)
  await review.getByRole('button', { name: 'Review them one by one', exact: true }).click()
  await expect(review.getByText('Is this the same charge as one you already have?', { exact: true })).toHaveCount(2)
  await page.reload()
  await expect(review.getByRole('button', { name: 'Leave them out', exact: true })).toBeVisible()
  await review.getByRole('button', { name: 'Leave them out', exact: true }).click()
  await expect(review.getByText('All 2 lines are saved.')).toBeVisible()
  await review.getByText('See all 2 lines', { exact: true }).click()
  await expect(review.getByText('Left out', { exact: true })).toHaveCount(2)
  const report = await api<{ spending_report: { totals: { actual: number } } }>('participant', '/api/v1/spending_report?start_on=2026-09-01&end_on=2026-09-30')
  expect(report.spending_report.totals.actual).toBe(60)
  await review.locator('table').getByRole('button', { name: 'Island Demo Mart', exact: true }).first().click()
  await expect(page.getByRole('dialog', { name: 'Island Demo Mart', exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'Close', exact: true }).click()
})
