import { expect, test, type Locator } from '@playwright/test'

async function reviewIdentityDetails(batch: Locator, savedIdentities = [101, 101, 201, 201, 301, 301]) {
  const rows = batch.getByRole('article')
  await expect(rows).toHaveCount(6)
  for (const [index, currentIdentity] of [101, 101, 201, 201, 301, 301].entries()) {
    const row = rows.nth(index)
    await expect(row.getByText('Current reviewed account: Fictional shared checking · Bank / wallet', { exact: true })).toBeVisible()
    const details = row.locator('details.source-review-technical')
    if (await details.getAttribute('open') === null) await details.locator('summary').click()
    await expect(row.getByText(`Current account review: version 2 · identity ID ${currentIdentity}. Saved facts account identity ID: ${savedIdentities[index]}.`, { exact: true })).toBeVisible()
  }
}

test('BOG UI selected batch corrects identity v1 to v2 for six rows without changing financial facts or spending', async ({ page }) => {
  await page.goto('/e2e/fixtures/statement-batch.html')
  await page.evaluate(() => document.fonts.ready)
  const batch = page.getByRole('region', { name: 'Review explicitly selected rows', exact: true })
  const confirmation = batch.getByRole('checkbox', { name: /I checked every displayed account/ })
  const stage = batch.getByRole('button', { name: 'Save selected row proposals', exact: true })
  await batch.getByLabel('Selected-row review note').fill('Checked all six fictional rows and corrected account identities.')
  await confirmation.check()
  await expect(stage).toBeEnabled()
  await page.getByRole('button', { name: 'Correct reviewed account identities to version 2' }).click()
  await expect(confirmation).not.toBeChecked()
  await expect(stage).toBeDisabled()
  await reviewIdentityDetails(batch)
  await expect(batch.getByText(/Spending: unchanged at/)).toHaveCount(6)
  await confirmation.check()
  await stage.click()
  await expect(page.getByRole('status', { name: 'Fixture submissions' })).toHaveText('6 synthetic review requests submitted')
  await expect(batch.getByRole('status')).toHaveText('6 of 6 proposals saved for review.')
  await expect(confirmation).not.toBeChecked()
  const approve = batch.getByRole('button', { name: 'Approve selected saved proposals', exact: true })
  await expect(approve).toBeDisabled()
  await expect(batch.getByText('Saved proposal account: Fictional shared checking · matches the current reviewed account.', { exact: true })).toHaveCount(6)
  await reviewIdentityDetails(batch)
  await confirmation.check()
  await approve.click()
  await expect(page.getByRole('status', { name: 'Fixture submissions' })).toHaveText('12 synthetic review requests submitted')
  await expect(batch.getByRole('status')).toHaveText('6 of 6 saved proposals approved.')
  await page.getByText('Inspect synthetic request payloads').click()
  const requests = JSON.parse((await page.getByTestId('fixture-requests').textContent())!)
  expect(requests.slice(0, 6).map((request: { input: { event_id: number } }) => request.input.event_id)).toEqual([4003, 4005, 4006, 4007, 4008, 4009])
  expect(requests.slice(0, 6).map((request: { input: { facts: { source_account_identity_version_id: number } } }) => request.input.facts.source_account_identity_version_id)).toEqual([101, 101, 201, 201, 301, 301])
  for (const [index, request] of requests.slice(0, 6).entries()) {
    expect(request.input.projection).toEqual({ action: 'none' })
    expect(request.input.facts).toMatchObject({ signed_amount_cents: -1_000 - index, purchase_amount_cents: 1_000 + index,
      posted_on: '2026-09-15', authorized_on: '2026-09-14', merchant: `Reviewed fictional row ${index + 1}`,
      budget_category_id: 10, overlap_disposition: 'distinct', external_reference: `fictional-ref-${index}` })
  }
  expect(requests.slice(6).map((request: { action: string }) => request.action)).toEqual(Array(6).fill('approve'))
  expect(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1)).toBe(false)
})

test('BOG UI selected batch never rewrites or approves a historical pending identity after account correction', async ({ page }) => {
  await page.goto('/e2e/fixtures/statement-batch.html')
  await page.evaluate(() => document.fonts.ready)
  await page.getByRole('button', { name: 'Correct reviewed account identities to version 2' }).click()
  await page.getByRole('button', { name: 'Load saved proposal on old identity' }).click()
  const batch = page.getByRole('region', { name: 'Review explicitly selected rows', exact: true })
  await expect(batch.getByText(/Saved proposal account:.*differs from the current reviewed account and requires individual review before approval/)).toHaveCount(6)
  await reviewIdentityDetails(batch, [100, 100, 200, 200, 300, 300])
  await expect(batch.getByText('Saved review note: Historical saved v1 proposal')).toHaveCount(6)
  await batch.getByLabel('Selected-row review note').fill('A historical pending proposal must be resolved individually.')
  await batch.getByRole('checkbox', { name: /I checked every displayed account/ }).check()
  await expect(batch.getByRole('button', { name: 'Save selected row proposals', exact: true })).toBeDisabled()
  await expect(batch.getByRole('button', { name: 'Approve selected saved proposals', exact: true })).toBeDisabled()
  await expect(page.getByRole('status', { name: 'Fixture submissions' })).toHaveText('0 synthetic review requests submitted')
  await reviewIdentityDetails(batch, [100, 100, 200, 200, 300, 300])
  expect(await batch.evaluate((node) => node.scrollWidth > node.clientWidth + 1)).toBe(false)
})
