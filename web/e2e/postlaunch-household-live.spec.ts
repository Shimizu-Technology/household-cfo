import { expect, test } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { mkdir } from 'node:fs/promises'

const live = process.env.HCFO_W14_LIVE_URL
const api = process.env.HCFO_W14_API_URL
const fixtureFile = process.env.HCFO_W14_FIXTURE_FILE
const fixtures = fixtureFile ? JSON.parse(readFileSync(fixtureFile, 'utf8')) : null
const evidence = process.env.HCFO_W14_EVIDENCE_DIR

test('Coach Studio BOG UI an old household draft goes live with Statements and completes review against Rails', async ({ page, context, request }, info) => {
  test.skip(!live || !api || !fixtures, 'Requires dedicated synthetic fixtures and local Rails')
  test.setTimeout(240_000)
  const fixture = fixtures.postlaunch[info.project.name]
  let coach = true
  await context.route(`${api}/**`, async route => {
    const authorization = coach
      ? `Bearer test_token:${fixture.coach_clerk_id}:${fixture.coach_email}:Mel:Fictional`
      : `Bearer test_token:${fixture.clerk_id}:${fixture.email}:Ana:Fictional`
    const headers = { ...route.request().headers(), Authorization: authorization }
    if (new URL(route.request().url()).pathname === '/api/v1/auth/me') {
      const response = await route.fetch({ headers })
      const payload = await response.json()
      expect(payload.user.id).toBe(coach ? fixture.coach_id : fixture.id)
      return route.fulfill({ response, json: { ...payload, user: { ...payload.user, clerk_id: coach ? 'e2e_coach' : 'e2e_participant' } } })
    }
    return route.continue({ headers })
  })
  if (info.project.name === 'desktop-chrome') await page.setViewportSize({ width: 1366, height: 900 })
  await page.goto(`${live}/?pilot_e2e_role=coach&pilot_e2e_live_api=true#Coach%20Studio`)
  await page.getByRole('navigation', { name: 'Coach Studio areas' }).getByRole('button', { name: 'Go live', exact: true }).click()
  await expect(page.getByText('This update adds Statements', { exact: true })).toBeVisible({ timeout: 60_000 })
  await expect(page.getByRole('button', { name: 'Approve and go live' })).toBeEnabled()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
  if (evidence) { await mkdir(evidence, { recursive: true }); await page.screenshot({ path: `${evidence}/${info.project.name}-go-live-upgrade.png`, fullPage: true, scale: 'css' }) }
  await page.getByRole('button', { name: 'Approve and go live' }).click()
  await expect(page.getByRole('status').filter({ hasText: `Live for ${fixture.group_name}` })).toBeVisible({ timeout: 60_000 })
  coach = false
  await page.goto(`${live}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Statements`)
  const review = page.getByRole('region', { name: 'Statement review' })
  await expect(review.getByRole('heading', { name: /1 line from Checking/ })).toBeVisible({ timeout: 60_000 })
  await review.getByRole('button', { name: 'Nothing’s missing' }).click()
  const saved = page.waitForResponse(response => response.url().includes('/review/approve_lines') && response.request().method() === 'POST')
  await review.getByRole('combobox', { name: 'Category for Fictional Market' }).selectOption({ label: 'Groceries' })
  const result = await saved
  expect(result.status(), await result.text()).toBe(200)
  await expect(review).toContainText('All 1 line is saved.', { timeout: 60_000 })
  const authorization = `Bearer test_token:${fixture.clerk_id}:${fixture.email}:Ana:Fictional`
  const workspace = await request.get(`${api}/api/v1/workspace`, { headers: { Authorization: authorization, 'X-Cohort-Id': String(fixture.cohort_id) } })
  const data = await workspace.json()
  expect(data.workspace.capabilities.schema_version).toBe(4)
  expect(data.profile.coach.name).toBe(fixture.persona_name)
  expect(data.workspace.capabilities.modules.find((module: {id: string}) => module.id === 'statements').enabled).toBe(true)
  const persisted = await request.get(`${api}/api/v1/document_imports/${fixture.import_id}/source_review?revision_id=${fixture.revision_id}&page=1&per_page=50&filter=all`, { headers: { Authorization: authorization, 'X-Cohort-Id': String(fixture.cohort_id) } })
  const plan = (await persisted.json()).source_review.participant_review.plan
  expect(plan.done).toBe(1)
  expect(plan.coverage.answer).toBe('nothing_missing')
  if (evidence) { await review.scrollIntoViewIfNeeded(); await page.screenshot({ path: `${evidence}/${info.project.name}-postlaunch-completed.png`, fullPage: false, scale: 'css' }) }
})

test('BOG UI a sealed V1 household hides Statements and refuses uploads against Rails', async ({ page, context, request }, info) => {
  test.skip(!live || !api || !fixtures, 'Requires dedicated synthetic fixtures and local Rails')
  test.setTimeout(240_000)
  const fixture = fixtures.v1[info.project.name]
  const authorization = `Bearer test_token:${fixture.clerk_id}:${fixture.email}:Ana:Fictional`
  await context.route(`${api}/**`, async route => {
    const headers = { ...route.request().headers(), Authorization: authorization }
    if (new URL(route.request().url()).pathname === '/api/v1/auth/me') {
      const response = await route.fetch({ headers })
      const payload = await response.json()
      return route.fulfill({ response, json: { ...payload, user: { ...payload.user, clerk_id: 'e2e_participant' } } })
    }
    return route.continue({ headers })
  })
  if (info.project.name === 'desktop-chrome') await page.setViewportSize({ width: 1366, height: 900 })
  await page.goto(`${live}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Statements`)
  await expect(page.getByRole('status').getByText("Statements aren't available for your group yet. Please contact your program team.", { exact: true })).toBeVisible({ timeout: 60_000 })
  await expect(page.getByRole('button', { name: 'Statements', exact: true })).toHaveCount(0)
  await expect(page.getByRole('link', { name: 'Statements', exact: true })).toHaveCount(0)
  await expect(page.getByRole('region', { name: 'Statement review' })).toHaveCount(0)
  await expect(page.locator('input[type=file]')).toHaveCount(0)
  const denied = await request.post(`${api}/api/v1/document_imports/presign`, { headers: { Authorization: authorization, 'X-Cohort-Id': String(fixture.cohort_id) }, data: {} })
  expect(denied.status()).toBe(403)
  if (evidence) { await mkdir(evidence, { recursive: true }); await page.screenshot({ path: `${evidence}/${info.project.name}-v1-statements-hidden.png`, fullPage: false, scale: 'css' }) }
  await page.getByRole('link', { name: `Ask ${fixture.persona_name}`, exact: true }).click()
  await expect(page.getByRole('button', { name: 'Attach receipt, screenshot, statement, or budget file', exact: true })).toBeDisabled()
})
