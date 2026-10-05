import { expect, test } from '@playwright/test'
test('BOG UI private controls review exact records, metadata erasure and keyboard containment without overflow', async ({ page }, testInfo) => {
  await page.goto('/privacy-qa.html')
  const opener = page.getByRole('button', { name: 'Open private controls' }); await opener.focus(); await opener.press('Enter')
  const dialog = page.getByRole('dialog'); await expect(dialog).toBeVisible(); await expect(page.getByText('No sharing grants.')).toBeVisible()
  await page.getByRole('combobox', { name: 'Purpose', exact: true }).selectOption('selected_details'); await page.getByRole('combobox', { name: 'Exact recipient', exact: true }).selectOption('903')
  await page.getByRole('button', { name: 'Find exact records' }).first().click(); await page.getByRole('checkbox', { name: /Fictional sample statement/ }).check()
  await page.getByRole('button', { name: 'Review sharing choice' }).click(); await expect(page.getByText(/Share ENTIRE selected records/)).toBeVisible(); await expect(page.getByRole('button', { name: 'Approve reviewed change' })).toBeDisabled()
  await page.getByRole('button', { name: 'Back without approval' }).click(); await page.locator('summary').filter({ hasText: 'Erase optional feelings' }).click(); await page.getByRole('button', { name: 'Review erase reflection 700' }).click(); await expect(page.getByText(/All historical optional feeling text/)).toBeVisible()
  await page.getByRole('checkbox', { name: 'I understand and approve this exact change.' }).check(); await page.getByRole('button', { name: 'Approve reviewed change' }).click(); await expect(page.getByText('Your reviewed choice was saved.')).toBeVisible()
  await page.locator('summary').filter({ hasText: 'Daily reminders' }).click(); await expect(page.getByRole('checkbox', { name: /I consent to a generic daily email/ })).not.toBeChecked(); await page.getByRole('button', { name: 'Review dismiss reminder' }).click(); await expect(page.getByText(/Dismissal does not record spending/)).toBeVisible()
  const bounds = await dialog.boundingBox(); const size = page.viewportSize()!; expect(bounds!.x).toBeGreaterThanOrEqual(0); expect(bounds!.width).toBeLessThanOrEqual(size.width); expect(bounds!.height).toBeLessThanOrEqual(size.height)
  expect(await page.evaluate(() => document.querySelector('.privacy-scroll')!.scrollWidth <= document.querySelector('.privacy-scroll')!.clientWidth)).toBe(true)
  await page.screenshot({ path: testInfo.outputPath('synthetic-privacy.png'), fullPage: true })
  await page.getByRole('button', { name: 'Close privacy controls' }).focus(); for (let i = 0; i < 12; i++) { await page.keyboard.press('Tab'); expect(await page.evaluate(() => Boolean(document.activeElement?.closest('dialog')))).toBe(true) }
  await page.keyboard.press('Escape'); await expect(dialog).not.toBeVisible(); await expect(opener).toBeFocused()
})

test('BOG UI uncertain privacy write checks status before retrying and cold held controls remain reachable', async ({ page }) => {
  await page.goto('/privacy-qa.html?scenario=uncertain'); await page.getByRole('button', { name: 'Open private controls' }).click()
  await page.getByRole('combobox', { name: 'Exact recipient', exact: true }).selectOption('903'); await page.getByRole('button', { name: 'Review sharing choice' }).click()
  await page.getByRole('checkbox', { name: 'I understand and approve this exact change.' }).check(); await page.getByRole('button', { name: 'Approve reviewed change' }).click()
  await expect(page.getByText(/server did not confirm/)).toBeVisible(); await expect(page.getByRole('button', { name: 'Approve reviewed change' })).toBeDisabled(); await expect(page.getByRole('button', { name: 'Retry exact reviewed request' })).toHaveCount(0)
  const identity = await page.evaluate(() => sessionStorage.getItem('challenge-private-request-identity-v1')); expect(identity).not.toContain('selected_records')
  await page.getByRole('button', { name: 'Check earlier request' }).click(); await page.getByRole('button', { name: 'Retry exact reviewed request' }).click(); await expect(page.getByText('Your reviewed choice was saved.')).toBeVisible()
  await page.goto('/privacy-qa.html?scenario=held'); await page.getByRole('button', { name: 'Open private controls' }).click(); await expect(page.getByRole('button', { name: 'Review revoke sharing' })).toBeEnabled()
  await page.getByRole('combobox', { name: 'Purpose', exact: true }).selectOption('selected_details'); await page.getByRole('button', { name: 'Find exact records' }).first().click(); await expect(page.getByText('Synthetic program held. New sharing unavailable.')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Review revoke sharing' })).toBeEnabled(); await page.locator('summary').filter({ hasText: 'Erase optional feelings' }).click(); await expect(page.getByRole('button', { name: 'Review erase reflection 700' })).toBeEnabled()
})
