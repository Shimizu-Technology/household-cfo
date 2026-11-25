import path from 'node:path'
import { test, expect, signIn, openSection, showBudgetMonth } from './stack'

test('Talun actual income against its plan @saves', async ({page}) => {
  await signIn(page, 'participant')
  await openSection(page, 'Statements')
  await page.locator('input[type=file]').first().setInputFiles(path.resolve('../api/test/fixtures/files/documents/talun-year/bog-2026-11-phone-1.png'))
  await expect(page.getByText('2 look right. 3 need a quick look.')).toBeVisible({timeout:90_000})
  await page.getByRole('button', {name:'Nothing’s missing'}).click()
  await page.getByRole('button', {name:'Approve the other 2'}).click()
  await page.getByLabel('Category for Tasi Demo Market', {exact:true}).selectOption({label:'Flexible spending'})
  await page.getByLabel('Category for Branch - Hagatna DEMO', {exact:true}).selectOption({label:'Flexible spending'})
  await page.getByRole('button', {name:/^Yes: Transfer from own checking/}).click()
  await openSection(page, 'Budget')
  await showBudgetMonth(page, 2026, 'Nov')
  const guamMonth = new Intl.DateTimeFormat('en-CA', { timeZone: 'Pacific/Guam', year: 'numeric', month: '2-digit' }).formatToParts(new Date())
  const year = guamMonth.find(part => part.type === 'year')!.value
  const month = guamMonth.find(part => part.type === 'month')!.value
  const current = `${year}-${month}`
  const expected = current < '2026-11' ? 'Money in: Not known yet of $5,400 planned'
    : `$1,650 ${current === '2026-11' ? 'in so far' : 'came in'} of $5,400 planned`
  await expect(page.getByText(expected, { exact: true })).toBeVisible()
  console.log(await page.locator('main').innerText())
  await page.screenshot({path:'/tmp/hcfo-income-statements.png', fullPage:true})
})
