import { test, expect } from '@playwright/test'
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs'
const fixtures = process.env.HCFO_W16_FIXTURES ? JSON.parse(readFileSync(process.env.HCFO_W16_FIXTURES, 'utf8')) : null
const live = process.env.HCFO_W16_WEB
const api = process.env.HCFO_W16_API
const evidence = process.env.HCFO_W16_EVIDENCE

test('Coach Studio pending and revoked invitations allow updates with an accepted person and remember the admin program', async ({ page, context, request }, info) => {
  test.skip(!fixtures || !live || !api, 'Requires isolated W16 Rails fixtures')
  test.setTimeout(360_000)
  const fixture = fixtures[info.project.name]
  const headers = { Authorization: `Bearer test_token_${fixture.coach_id}`, 'X-Coach-Workspace-Id': String(fixture.workspace_id) }
  for (const id of fixture.group_ids) {
    const roster = await request.get(`${api}/api/v1/admin/cohorts/${id}/rollouts`, { headers })
    expect(roster.status()).toBe(200)
    const payload = await roster.json()
    const studio = payload.cohort_rollout_studio ?? payload.rollout_studio ?? payload
    expect(studio.current_roster.participants).toHaveLength(1)
    expect(studio.active_release).toBeNull()
  }
  const launches: Array<Record<string, unknown>> = []
  await context.route(`${api}/**`, async route => {
    const response = await route.fetch({ headers: { ...route.request().headers(), Authorization: headers.Authorization } })
    if (new URL(route.request().url()).pathname === '/api/v1/auth/me') {
      const payload = await response.json()
      return route.fulfill({ response, json: { ...payload, user: { ...payload.user, clerk_id: 'e2e_admin' } } })
    }
    if (route.request().url().endsWith('/go_live')) {
      expect(response.status(), await response.text()).toBe(200)
      launches.push((await response.json()).launch)
    }
    return route.fulfill({ response })
  })
  if (info.project.name === 'desktop-chrome') await page.setViewportSize({ width: 1366, height: 900 })
  const shot = async (name: string) => {
    if (!evidence) return
    mkdirSync(evidence, { recursive: true })
    await page.screenshot({ path: `${evidence}/${info.project.name}-${name}.png`, fullPage: true, scale: 'css' })
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
  }
  await page.goto(`${live}/?pilot_e2e_role=admin&pilot_e2e_live_api=true#Coach%20Studio`)
  await page.getByLabel('Program', { exact: true }).selectOption(String(fixture.workspace_id))
  const areas = page.getByRole('navigation', { name: 'Coach Studio areas' })
  await areas.getByRole('button', { name: 'Go live', exact: true }).click()
  await expect(page.getByText('Review before going live')).toBeVisible({ timeout: 60_000 })
  await shot('pending-review')
  await page.getByRole('button', { name: 'Approve and go live', exact: true }).click()
  await expect.poll(async () => await page.getByRole('status').filter({ hasText: 'Live for' }).isVisible() || await page.getByRole('button', { name: 'Check this update', exact: true }).isVisible(), { timeout: 120_000 }).toBe(true)
  if (!await page.getByRole('status').filter({ hasText: 'Live for' }).isVisible()) await page.getByRole('button', { name: 'Check this update', exact: true }).click()
  await expect(page.getByRole('status').filter({ hasText: 'Live for' })).toBeVisible({ timeout: 120_000 })
  await shot('first-live')
  const added = await request.patch(`${api}/api/v1/admin/users/${fixture.accepted_id}`, { headers: { Authorization: headers.Authorization }, data: { user: { cohort_ids: [fixture.group_ids[0]] } } })
  expect(added.status(), await added.text()).toBe(200)
  await areas.getByRole('button', { name: 'Your assistant', exact: true }).click()
  await page.getByText('More settings', { exact: true }).click()
  await page.getByRole('button', { name: 'Appearance', exact: true }).click()
  const name = `Updated program ${info.project.name}`
  await page.getByLabel('App name', { exact: true }).fill(name)
  const saving = page.waitForResponse(response => response.url().endsWith('/brand') && response.request().method() === 'PATCH')
  await page.getByRole('button', { name: 'Save brand draft', exact: true }).click()
  expect((await saving).status()).toBe(200)
  await shot('edited-brand')
  await page.reload()
  await expect(page.getByLabel('Program', { exact: true })).toHaveValue(String(fixture.workspace_id))
  await areas.getByRole('button', { name: 'Go live', exact: true }).click()
  await expect(page.getByText('Review before going live')).toBeVisible({ timeout: 60_000 })
  await shot('update-review')
  await page.getByRole('button', { name: 'Approve and go live', exact: true }).click()
  await expect.poll(async () => await page.getByRole('status').filter({ hasText: 'Live for' }).isVisible() || await page.getByRole('button', { name: 'Check this update', exact: true }).isVisible(), { timeout: 120_000 }).toBe(true)
  if (!await page.getByRole('status').filter({ hasText: 'Live for' }).isVisible()) await page.getByRole('button', { name: 'Check this update', exact: true }).click()
  await expect(page.getByRole('status').filter({ hasText: 'Live for' })).toBeVisible({ timeout: 120_000 })
  await shot('updated-live')
  expect(launches).toHaveLength(2)
  const saved = []
  for (const id of fixture.group_ids) {
    const response = await request.get(`${api}/api/v1/admin/cohorts/${id}/releases`, { headers })
    expect(response.status()).toBe(200)
    const releases = await response.json()
    const rolloutResponse = await request.get(`${api}/api/v1/admin/cohorts/${id}/rollouts`, { headers })
    expect(rolloutResponse.status()).toBe(200)
    const rollout = await rolloutResponse.json()
    expect(JSON.stringify(releases)).toContain(name)
    expect(JSON.stringify(rollout)).toContain('completed')
    saved.push({ id, releases, rollout })
  }
  if (evidence) writeFileSync(`${evidence}/${info.project.name}-saved.json`, JSON.stringify({ launches, saved }, null, 2))
})
