import { test, expect as playwrightExpect } from '@playwright/test'
const expect = playwrightExpect.configure({ timeout: 60_000 })
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs'
const fixturePath = process.env.HCFO_W19_FIXTURES
const fixtures = fixturePath ? JSON.parse(readFileSync(fixturePath, 'utf8')) : null
const web = process.env.HCFO_W19_WEB
const api = process.env.HCFO_W19_API
const evidence = process.env.HCFO_W19_EVIDENCE

test('Coach Studio fresh QA saves accumulated voice, reviews tools, invites a list and follows browser history against Rails', async ({ page, context, request }, info) => {
  test.skip(!fixtures || !web || !api, 'Requires isolated W19 Rails fixtures, captured real-model proposal and model disabled')
  test.setTimeout(360_000)
  const fixture = fixtures[info.project.name]
  const headers = { Authorization: `Bearer test_token_${fixture.coach_id}`, 'X-Coach-Workspace-Id': String(fixture.workspace_id) }
  await context.route(`${api}/**`, async route => {
    const authHeaders = { ...route.request().headers(), Authorization: headers.Authorization }
    if (new URL(route.request().url()).pathname === '/api/v1/auth/me') {
      const response = await route.fetch({ headers: authHeaders })
      const payload = await response.json()
      return route.fulfill({ response, json: { ...payload, user: { ...payload.user, clerk_id: 'e2e_coach' } } })
    }
    return route.continue({ headers: authHeaders })
  })
  if (info.project.name === 'desktop-chrome') await page.setViewportSize({ width: 1366, height: 900 })
  const shot = async (name: string) => {
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    if (evidence) { mkdirSync(evidence, { recursive: true }); await page.screenshot({ path: `${evidence}/${info.project.name}-${name}.png`, fullPage: true, scale: 'css' }) }
  }
  await page.goto(`${web}/?pilot_e2e_role=coach&pilot_e2e_live_api=true#Home`)
  const areas = page.getByRole('navigation', { name: 'Coach Studio areas' })
  await expect(areas).toBeVisible()
  await expect(page.getByText('Household money is not available in this staff workspace.')).toHaveCount(0)
  await shot('people')
  // A real initial launch provides the baseline for the second tools review.
  const rolloutResponse = await request.get(`${api}/api/v1/admin/cohorts/${fixture.group_id}/rollouts`, { headers })
  expect(rolloutResponse.status()).toBe(200)
  const rolloutPayload = await rolloutResponse.json()
  const rollout = rolloutPayload.cohort_rollout_studio ?? rolloutPayload.rollout_studio ?? rolloutPayload
  if (!rollout.active_release) {
    await areas.getByRole('button', { name: 'Go live', exact: true }).click()
    await expect(page.getByText('Review before going live')).toBeVisible({ timeout: 60_000 })
    await page.getByRole('button', { name: 'Approve and go live', exact: true }).click()
    await expect(page.getByRole('status').filter({ hasText: 'Live for' })).toBeVisible({ timeout: 60_000 })
  }
  await areas.getByRole('button', { name: 'Your assistant', exact: true }).click()
  await page.getByText('More settings', { exact: true }).click()
  await page.getByRole('button', { name: 'Tools', exact: true }).click()
  await page.getByRole('switch', { name: 'Include CFO Filter' }).check()
  await page.getByRole('button', { name: 'Move CFO Filter up', exact: true }).click()
  await page.getByRole('button', { name: 'Save draft', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Save draft', exact: true })).toBeDisabled()
  await areas.getByRole('button', { name: 'Go live', exact: true }).click()
  await expect(page.getByText('Adds CFO Filter.', { exact: true })).toBeVisible({ timeout: 60_000 })
  await expect(page.getByText('Changes the order of the tools shown below.')).toBeVisible()
  await shot('second-tools-review')
  await page.goBack()
  await expect(page.getByRole('switch', { name: 'Include CFO Filter' })).toBeChecked()
  await page.goForward()
  await expect(page.getByText('Adds CFO Filter.', { exact: true })).toBeVisible({ timeout: 60_000 })
  await areas.getByRole('button', { name: 'Your assistant', exact: true }).click()
  await page.getByText('More settings', { exact: true }).click()
  await page.getByRole('button', { name: '1 · Your coach’s voice', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Use all suggestions' })).toBeEnabled({ timeout: 60_000 })
  await expect(page.getByText('Answers: 3 to 4 sentences', { exact: true })).toBeVisible()
  await shot('accumulated-voice')
  await page.getByLabel('Message Mia').fill('Tell me more about this voice.')
  await page.getByRole('button', { name: 'Send to Mia', exact: true }).click()
  await expect(page.getByRole('alert').filter({ hasText: /could not prepare/ })).toBeVisible({ timeout: 60_000 })
  await expect(page.getByLabel('Message Mia')).toHaveValue('Tell me more about this voice.')
  await expect(page.getByRole('button', { name: 'Use all suggestions', exact: true })).toBeEnabled()
  await page.getByLabel('Message Mia').fill('')
  await page.reload()
  await expect(page.getByRole('button', { name: 'Use all suggestions' })).toBeEnabled({ timeout: 60_000 })
  await page.getByRole('button', { name: 'Review in form', exact: true }).click()
  await expect(page.getByLabel('Message Mia')).toBeHidden()
  await expect(page.getByRole('checkbox', { name: 'Keep: Assistant name' })).toBeVisible()
  await expect(page.getByText('Unsaved changes', { exact: true })).toHaveCount(0)
  await shot('focused-review')
  if (info.project.name === 'mobile-webkit') {
    await page.setViewportSize({ width: 320, height: 568 }); await shot('focused-review-320'); await page.setViewportSize({ width: 390, height: 844 })
  }
  await page.getByRole('button', { name: 'Use all suggestions', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'Hear your assistant, then go live' })).toBeVisible()
  const saved = await request.get(`${api}/api/v1/admin/personas/${fixture.persona_id}`, { headers })
  expect(saved.status()).toBe(200)
  const config = (await saved.json()).persona.draft
  expect(config.identity.assistant_name).toBe('Lani')
  expect(config.response_shape.min_sentences).toBe(3); expect(config.response_shape.max_sentences).toBe(4)
  expect(config.phrases.map((phrase: { text: string }) => phrase.text)).toEqual(['Chelu, pump the brakes.'])
  expect(config.coaching.do).toContain('Celebrate small wins.')
  expect(config.coaching.do_not).toContain('Never shame anyone.')
  if (evidence) writeFileSync(`${evidence}/${info.project.name}-saved-voice.json`, JSON.stringify(config, null, 2))
  await areas.getByRole('button', { name: 'Your assistant', exact: true }).click()
  await page.getByText('More settings', { exact: true }).click()
  await page.getByRole('button', { name: '2 · Teaching', exact: true }).click()
  await page.getByText('Add a phrase in your own words', { exact: true }).click()
  await page.getByLabel('Phrase', { exact: true }).fill('One small step is still a step.')
  expect((await page.getByLabel('Phrase', { exact: true }).boundingBox())!.height).toBeGreaterThanOrEqual(44)
  await page.getByLabel('What it means (optional)').fill('Celebrate progress at your own pace.')
  await shot('manual-phrase')
  await page.getByRole('button', { name: 'Save and preview answers', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'Hear your assistant, then go live' })).toBeVisible()
  const manual = await request.get(`${api}/api/v1/admin/personas/${fixture.persona_id}`, { headers })
  expect((await manual.json()).persona.draft.phrases.map((phrase: { text: string }) => phrase.text)).toContain('One small step is still a step.')
  await areas.getByRole('button', { name: 'People', exact: true }).click()
  await page.getByRole('button', { name: 'Invite someone', exact: true }).click()
  const invitation = page.locator('details.coach-group-settings').filter({ has: page.locator('summary', { hasText: /^Add a participant$/ }) })
  const runKey = `${fixture.workspace_id}-${Date.now().toString(36)}`
  const firstEmail = `ana-${runKey}@example.invalid`
  await page.getByLabel('Participant email', { exact: true }).fill(firstEmail)
  await page.getByRole('button', { name: `Add to W19 ${info.project.name} Group`, exact: true }).click()
  await expect(page.getByText(/Participant added. The invitation email did not send/)).toBeVisible()
  await expect(invitation).toHaveAttribute('open', '')
  await expect(page.getByLabel('Participant email', { exact: true })).toHaveValue('')
  await expect(page.getByText(/WorkOS authentication is not configured/)).toHaveCount(0)
  await shot('invite-failure')
  const emails = Array.from({ length: 30 }, (_, index) => `person-${index}-${runKey}@example.invalid`)
  await page.getByLabel('Paste email addresses').fill(emails.join('\n'))
  await page.getByRole('button', { name: 'Review email list', exact: true }).click()
  await expect(page.getByRole('heading', { name: `Review 30 people for W19 ${info.project.name} Group`, exact: true })).toBeVisible()
  await shot('bulk-review')
  await page.getByRole('button', { name: 'Add these 30 people', exact: true }).click()
  await expect(page.getByText(/30 people added/)).toBeVisible({ timeout: 240_000 })
  await expect(page.getByLabel('Paste email addresses')).toHaveValue('')
  await shot('bulk-saved')
  const roster = await request.get(`${api}/api/v1/admin/users`, { headers })
  expect(roster.status()).toBe(200)
  const json = await roster.json()
  const users = json.users
  expect(emails.every(email => users.some((user: { email: string }) => user.email === email))).toBe(true)
})
