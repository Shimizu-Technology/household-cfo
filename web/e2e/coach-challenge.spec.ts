import { expect, test } from '@playwright/test'
const fit = async (page: import('@playwright/test').Page) => expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)

test('BOG UI Coach Studio metadata and explicit current sharing fit each viewport', async ({ page }, info) => {
  await page.goto('/e2e/fixtures/coach-challenge.html')
  await page.getByRole('button', { name: /Fictional pilot participant/ }).click()
  await expect(page.getByRole('dialog')).toContainText('Fictional pilot participant')
  await expect(page.getByText(/\$100.00 reported/)).toHaveCount(0)
  await page.getByRole('button', { name: 'View shared progress' }).click()
  await expect(page.getByText(/\$100.00 reported/)).toBeVisible()
  await page.evaluate(() => (window as unknown as { __revoke: () => void }).__revoke())
  await page.getByRole('button', { name: 'Refresh shared items' }).click()
  await expect(page.getByRole('alert')).toContainText('Synthetic sharing revoked')
  await expect(page.getByText(/\$100.00 reported/)).toHaveCount(0)
  await fit(page)
  await page.screenshot({ path: info.outputPath('synthetic-coach-private-view.png'), fullPage: true })
})

test('BOG UI fixed coarse report review and private export choices are explicit', async ({ page }) => {
  await page.goto('/e2e/fixtures/coach-challenge.html')
  const day30 = page.locator('.admin-report-row', { hasText: 'Day 30' }).first()
  await expect(day30).toContainText('Report saved')
  await expect(page.locator('.admin-report-row', { hasText: 'Day 90' }).first()).not.toContainText('Save the report')
  await page.locator('.admin-report-row', { hasText: 'Day 60' }).first().getByRole('button', { name: 'Save the report' }).click()
  const save = page.getByRole('dialog')
  await expect(save.getByRole('button', { name: 'Save the report' })).toBeDisabled()
  await save.getByRole('checkbox', { name: /I understand it shows broad ranges only/ }).check()
  await save.getByRole('button', { name: 'Save the report' }).click()
  await expect(page.getByText('Fewer than five people agreed to share, so progress is hidden.')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Download this report' })).toBeVisible()
  await page.getByRole('dialog').getByRole('button', { name: 'Close' }).click()
  await page.getByText('Download your record', { exact: true }).click()
  await expect(page.getByRole('checkbox', { name: /Include my optional feeling history/ })).not.toBeChecked()
  await expect(page.getByRole('button', { name: 'Download my record' })).toBeDisabled()
  await fit(page)
})

test('BOG UI household roster identifies setup help and every control is a comfortable target', async ({ page }, info) => {
  await page.goto('/e2e/fixtures/coach-challenge.html')
  await page.getByLabel('Group').selectOption({ index: 1 })
  await expect(page.getByText('Elena', { exact: true })).toBeVisible()
  await expect(page.getByText('Asked for help with an upload')).toBeVisible()
  // Reports are only for savings groups: the household group has none.
  await expect(page.locator('.admin-report-group h3', { hasText: 'Household group' })).toHaveCount(0)
  await page.getByRole('button', { name: /Elena/ }).click()
  await expect(page.getByRole('dialog')).toContainText('Asked for help with an upload')
  await page.getByRole('dialog').getByRole('button', { name: 'Close' }).click()
  // Safari does not focus a button when it is tapped, so there is nothing for the dialog to return to there.
  if (info.project.name !== 'mobile-webkit') await expect(page.getByRole('button', { name: /Elena/ })).toBeFocused()
  for (const control of await page.locator('.admin-section button:visible, .admin-section select:visible').all()) {
    expect((await control.boundingBox())!.height).toBeGreaterThanOrEqual(44)
  }
  await fit(page)
})
