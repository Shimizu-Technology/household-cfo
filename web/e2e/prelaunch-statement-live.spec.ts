import { expect, test } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { mkdir } from 'node:fs/promises'

const live = process.env.HCFO_W14_LIVE_URL
const api = process.env.HCFO_W14_API_URL
const fixtureFile = process.env.HCFO_W14_FIXTURE_FILE
const fixtures = fixtureFile ? JSON.parse(readFileSync(fixtureFile, 'utf8')) as Record<string, { id: number; clerk_id: string; email: string; cohort_id: number; import_id: number; revision_id: number }> : null

test('BOG UI a prelaunch participant finishes a statement against Rails', async ({ page, context, request }, info) => {
  test.skip(!live || !api || !fixtures, 'Requires a dedicated synthetic prelaunch fixture and local Rails server')
  test.setTimeout(120_000)
  const fixture = fixtures![info.project.name]
  test.skip(!fixture, 'No fixture for this project')
  const authorization = `Bearer test_token:${fixture.clerk_id}:${fixture.email}:Ana:Fictional`
  await context.route(`${api}/**`, async route => {
    const headers = { ...route.request().headers(), Authorization: authorization }
    if (new URL(route.request().url()).pathname === '/api/v1/auth/me') {
      const response = await route.fetch({ headers })
      const payload = await response.json()
      expect(payload.user.id).toBe(fixture.id)
      return route.fulfill({ response, json: { ...payload, user: { ...payload.user, clerk_id: 'e2e_participant' } } })
    }
    return route.continue({ headers })
  })
  let rejectFirstAnswer = true
  await context.route(`${api}/api/v1/document_imports/**/review/approve_lines`, async route => {
    if (!rejectFirstAnswer) return route.fallback()
    rejectFirstAnswer = false
    return route.fulfill({ status: 403, json: { code: 'savings_challenge_unavailable', errors: ['This part of your program is not available right now.'] } })
  })
  if (info.project.name === 'desktop-chrome') await page.setViewportSize({ width: 1366, height: 900 })
  await page.goto(`${live}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Statements`)
  const review = page.getByRole('region', { name: 'Statement review' })
  await expect(review.getByRole('heading', { name: /1 line from Checking/ })).toBeVisible({ timeout: 60_000 })
  if (info.project.name === 'compact-mobile-chrome' || info.project.name === 'mobile-webkit') {
    const first = await review.getByRole('button', { name: 'Nothing’s missing' }).boundingBox()
    const second = await review.getByRole('button', { name: 'Something’s missing' }).boundingBox()
    expect(second!.y).toBeGreaterThanOrEqual(first!.y + first!.height)
  }
  await review.getByRole('button', { name: 'Nothing’s missing' }).click()
  const category = review.getByRole('combobox', { name: 'Category for Fictional Market' })
  await category.selectOption({ label: 'Groceries' })
  const retry = review.getByRole('button', { name: 'Try saving this answer again' })
  await expect(retry).toBeVisible()
  await expect(category.locator('option:checked')).toHaveText('Groceries')
  if (process.env.HCFO_W14_EVIDENCE_DIR) {
    await mkdir(process.env.HCFO_W14_EVIDENCE_DIR, { recursive: true })
    await review.scrollIntoViewIfNeeded()
    await page.screenshot({ path: `${process.env.HCFO_W14_EVIDENCE_DIR}/${info.project.name}-retry.png`, fullPage: true })
  }
  const saved = page.waitForResponse(response => response.url().includes('/review/approve_lines') && response.request().method() === 'POST')
  await retry.click()
  const result = await saved
  expect(result.status(), await result.text()).toBe(200)
  await expect(review).toContainText('All 1 line is saved.', { timeout: 60_000 })
  const response = await request.get(`${api}/api/v1/document_imports/${fixture.import_id}/source_review?revision_id=${fixture.revision_id}&page=1&per_page=50&filter=all`, { headers: { Authorization: authorization, 'X-Cohort-Id': String(fixture.cohort_id) } })
  expect(response.ok()).toBe(true)
  const plan = (await response.json()).source_review.participant_review.plan
  expect(plan.done).toBe(1)
  expect(plan.coverage.answer).toBe('nothing_missing')
  if (process.env.HCFO_W14_EVIDENCE_DIR) {
    await mkdir(process.env.HCFO_W14_EVIDENCE_DIR, { recursive: true })
    await review.scrollIntoViewIfNeeded()
    await page.screenshot({ path: `${process.env.HCFO_W14_EVIDENCE_DIR}/${info.project.name}-completed.png`, fullPage: true })
  }
})
