import path from 'node:path'
import { api, expect, openSection, showBudgetMonth, signIn, test } from './stack'

// A fictional bank CSV, read without any model. Its posted spending is $2,796.15 withdrawn, less a $200
// transfer to her own savings and a $250 card payment, and it has a $6.50 card authorization still
// pending: $2,339.65 of purchases. Its $12.99 Amazon refund goes back to the Amazon purchase's category
// in August, so $2,326.66 is what Budget must show for August once every line is saved.
const STATEMENT = path.resolve(import.meta.dirname, '../../api/test/fixtures/files/documents/bank-of-guam-2026-08.csv')

type Imports = { document_imports: Array<{ statement_review?: { total: number; done: number; without_category?: number; coverage?: { answer: string | null } } }> }

test('a fictional statement, reviewed by hand, saves exactly its posted spending @saves', async ({ page }) => {
  const before = await api<Imports>('participant', '/api/v1/document_imports')
  expect(before.document_imports, 'Run on a fresh stack: bin/local-stack reset, up, then local_stack:household').toHaveLength(0)

  await signIn(page, 'participant')
  await openSection(page, 'Statements')
  await page.locator('input[type=file]').first().setInputFiles(STATEMENT)
  await expect(page.getByText('23 look right. 4 need a quick look.')).toBeVisible({ timeout: 90_000 })

  // Which account this is comes first (#319): a new bank account on a fresh stack.
  await page.getByRole('button', { name: 'Choose account' }).click()
  const account = page.getByRole('dialog', { name: 'Your account' })
  const saved = account.getByRole('combobox', { name: 'Account', exact: true })
  if (await saved.count()) await saved.selectOption('new')
  await account.getByLabel('Name', { exact: true }).fill('Talun Checking')
  await account.getByRole('combobox', { name: 'Type', exact: true }).selectOption('asset')
  await account.getByRole('button', { name: 'Save' }).click()
  await expect(account).toBeHidden()
  await page.getByRole('button', { name: 'Nothing’s missing' }).click()
  await page.getByRole('button', { name: /^Yes: Coast360 transfer/ }).click()
  await expect(page.getByLabel('Category for ATM withdrawal Mangilao')).toBeEnabled()
  await page.getByLabel('Category for ATM withdrawal Mangilao').selectOption({ label: 'Flexible spending' })
  await page.getByRole('button', { name: /^Yes: Visa card payment/ }).click()
  await page.getByRole('button', { name: /^Yes: Amazon refund/ }).click()
  await page.getByRole('button', { name: 'Approve all 23' }).click()
  await expect(page.getByText('All 27 lines are saved.')).toBeVisible({ timeout: 60_000 })
  await expect.poll(async () => (await api<Imports>('participant', '/api/v1/document_imports')).document_imports[0]?.statement_review?.coverage?.answer).toBe('nothing_missing')

  const after = await api<Imports>('participant', '/api/v1/document_imports')
  expect(after.document_imports[0]?.statement_review).toMatchObject({ total: 27, done: 27, without_category: 0 })

  await openSection(page, 'Budget')
  await showBudgetMonth(page, 2026, 'Aug')
  await expect(page.getByText(/Approved spending:/)).toContainText('$2,326.66')
})

test('Budget shows the same August spending at phone width, with the year arrows beside the month @reads', async ({ page }) => {
  const ledger = await api<{ spending_report: { totals: { actual: number } } }>('participant', '/api/v1/spending_report?start_on=2026-08-01&end_on=2026-08-31')
  const expected = ledger.spending_report.totals.actual.toLocaleString('en-US', { style: 'currency', currency: 'USD' })
  await signIn(page, 'participant')
  await openSection(page, 'Budget')
  await showBudgetMonth(page, 2026, 'Aug')
  await expect(page.getByText(/Approved spending:/)).toContainText(expected)
  const month = await page.getByLabel('Report month').boundingBox()
  const next = await page.getByRole('button', { name: 'Next year' }).boundingBox()
  expect(Math.abs((next?.y ?? 0) - (month?.y ?? 999)), 'the next-year arrow stays on the month row').toBeLessThan(month?.height ?? 40)
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
})

test('Statements shows the saved statement at phone width @reads', async ({ page }) => {
  await signIn(page, 'participant')
  await openSection(page, 'Statements')
  await page.getByText('Find an upload', { exact: true }).click()
  await page.getByRole('textbox', { name: 'Search imports', exact: true }).fill('bank-of-guam-2026-08.csv')
  await page.getByRole('button', { name: /^bank-of-guam-2026-08.csv Statement/ }).click()
  await expect(page.getByText('All 27 lines are saved.')).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
})
