import path from 'node:path'
import { api, expect, openSection, showBudgetMonth, signIn, test } from './stack'

// A fictional bank CSV, read without any model. Its posted spending is $2,796.15 withdrawn, less a $200
// transfer to her own savings and a $250 card payment, and it has a $6.50 card authorization still
// pending: $2,339.65 of purchases. Its $12.99 Amazon refund goes back to the Amazon purchase's category
// in August, so $2,326.66 is what Budget must show for August once every line is saved.
const STATEMENT = path.resolve(import.meta.dirname, '../../api/test/fixtures/files/documents/bank-of-guam-2026-08.csv')

type Imports = { document_imports: Array<{ statement_review?: { total: number; done: number; without_category?: number } }> }

test('a fictional statement, reviewed by hand, saves exactly its posted spending @saves', async ({ page }) => {
  const before = await api<Imports>('participant', '/api/v1/document_imports')
  expect(before.document_imports, 'Run on a fresh stack: bin/local-stack reset, up, then local_stack:household').toHaveLength(0)

  await signIn(page, 'participant')
  await openSection(page, 'Statements')
  await page.locator('input[type=file]').first().setInputFiles(STATEMENT)
  await expect(page.getByText('23 look right. 4 need a quick look.')).toBeVisible({ timeout: 90_000 })

  await page.getByRole('button', { name: 'Nothing’s missing' }).click()
  await page.getByRole('button', { name: 'Bank account' }).click()
  await page.getByRole('button', { name: /^Yes: Coast360 transfer/ }).click()
  await expect(page.getByLabel('Category for ATM withdrawal Mangilao')).toBeEnabled()
  await page.getByLabel('Category for ATM withdrawal Mangilao').selectOption({ label: 'Flexible spending' })
  await page.getByRole('button', { name: /^Yes: Visa card payment/ }).click()
  await page.getByRole('button', { name: /^Yes: Amazon refund/ }).click()
  await page.getByRole('button', { name: 'Approve all 23' }).click()
  await expect(page.getByText('All 27 lines are saved.')).toBeVisible({ timeout: 60_000 })

  const after = await api<Imports>('participant', '/api/v1/document_imports')
  expect(after.document_imports[0]?.statement_review).toMatchObject({ total: 27, done: 27, without_category: 0 })

  await openSection(page, 'Budget')
  await showBudgetMonth(page, 2026, 'Aug')
  await expect(page.getByText(/Approved spending:/)).toContainText('$2,326.66')
})

test('Budget shows the same August spending at phone width, with the year arrows beside the month @reads', async ({ page }) => {
  await signIn(page, 'participant')
  await openSection(page, 'Budget')
  await showBudgetMonth(page, 2026, 'Aug')
  await expect(page.getByText(/Approved spending:/)).toContainText('$2,326.66')
  const month = await page.getByLabel('Report month').boundingBox()
  const next = await page.getByRole('button', { name: 'Next year' }).boundingBox()
  expect(Math.abs((next?.y ?? 0) - (month?.y ?? 999)), 'the next-year arrow stays on the month row').toBeLessThan(month?.height ?? 40)
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
})

test('Statements shows the saved statement at phone width @reads', async ({ page }) => {
  await signIn(page, 'participant')
  await openSection(page, 'Statements')
  await expect(page.getByText('All 27 lines are saved.')).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
})
