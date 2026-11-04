import { expect, test, type Response } from '@playwright/test'
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

for (const state of ['v1', 'hidden']) {
  for (const message of ['I stayed under my grocery budget this week', 'I want to kill myself']) {
    test(`BOG UI mobile Ask Mia ${state} Statements group sends ${message.includes('kill') ? 'crisis' : 'text'} messages against Rails`, async ({ page, context, request }, info) => {
      test.skip(!live || !api || !fixtures, 'Requires dedicated synthetic fixtures and local Rails')
      test.setTimeout(90_000)
      const fixture = fixtures[state][info.project.name]
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
    await page.goto(`${live}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Ask%20Mia`)
      const composer = page.getByRole('textbox', { name: `Ask ${fixture.persona_name}`, exact: true })
      let posted: Response | undefined
      page.on('response', response => { if (response.url().endsWith('/api/v1/mia/messages') && response.request().method() === 'POST') posted = response })
      await composer.fill(message)
      await page.getByRole('button', { name: `Send message to ${fixture.persona_name}` }).click()
      await expect.poll(() => posted?.status(), { timeout: 15_000 }).toBe(201)
      const reply = await posted!.json()
      await expect(composer).toHaveValue('')
      await expect(page.locator('.chat-card')).toContainText(message)
      await expect(page.getByRole('button', { name: `Send message to ${fixture.persona_name}` })).toBeVisible({ timeout: 60_000 })
      const persisted = await request.get(`${api}/api/v1/mia/messages`, { headers: { Authorization: authorization, 'X-Cohort-Id': String(fixture.cohort_id) } })
      expect(persisted.ok()).toBe(true)
      const messages = (await persisted.json()).messages
      expect(messages.some((saved: { role: string; content: string }) => saved.role === 'user' && saved.content === message)).toBe(true)
      if (message.includes('kill')) expect(reply.assistant_message.content).toMatch(/988|911/)
      if (evidence) { await mkdir(evidence, { recursive: true }); await page.screenshot({ path: `${evidence}/${info.project.name}-${state}-${message.includes('kill') ? 'crisis' : 'text'}.png`, scale: 'css' }) }
    })
  }
  test(`BOG UI mobile Ask Mia ${state} Statements group refuses every attachment entry point`, async ({ page, context }, info) => {
    test.skip(!live || !api || !fixtures, 'Requires dedicated synthetic fixtures and local Rails')
    test.setTimeout(90_000)
    const fixture = fixtures[state][info.project.name]
    const authorization = `Bearer test_token:${fixture.clerk_id}:${fixture.email}:Ana:Fictional`
    await context.route(`${api}/**`, async route => {
      const headers = { ...route.request().headers(), Authorization: authorization }
      if (new URL(route.request().url()).pathname === '/api/v1/auth/me') {
        const response = await route.fetch({ headers }); const payload = await response.json()
        return route.fulfill({ response, json: { ...payload, user: { ...payload.user, clerk_id: 'e2e_participant' } } })
      }
      return route.continue({ headers })
    })
    let uploads = 0
    page.on('request', request => { if (request.method() === 'POST' && request.url().includes('/document_imports')) uploads++ })
    if (info.project.name === 'desktop-chrome') await page.setViewportSize({ width: 1366, height: 900 })
    await page.goto(`${live}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Ask%20Mia`)
    const attach = page.getByRole('button', { name: 'Attach receipt, screenshot, statement, or budget file', exact: true })
    await expect(attach).toBeDisabled({ timeout: 60_000 })
    const reason = await attach.getAttribute('title')
    expect(reason).toMatch(/Statements/)
    // Exercise the shared handler directly as a stale file chooser can still fire change.
    await page.locator('.ask-row input[type=file]').setInputFiles({ name: 'fictional.csv', mimeType: 'text/csv', buffer: Buffer.from('date,amount\n2026-10-01,12') })
    await expect(page.getByRole('alert').filter({ hasText: reason! })).toBeVisible()
    await expect(page.locator('.composer-attachment-card')).toHaveCount(0)
    // Pasted images use the same boundary as the file chooser.
    await page.getByRole('textbox', { name: `Ask ${fixture.persona_name}`, exact: true }).evaluate(element => {
      const transfer = new DataTransfer(); transfer.items.add(new File(['synthetic'], 'fictional.png', { type: 'image/png' }))
      element.dispatchEvent(new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: transfer }))
    })
    await expect(page.locator('.composer-attachment-card')).toHaveCount(0)
    await page.getByRole('button', { name: 'More chat options' }).click()
    await page.getByRole('button', { name: 'Context & help' }).click()
    const secondary = page.getByRole('button', { name: 'Attach a file', exact: true })
    await expect(secondary).toBeDisabled()
    await expect(secondary).toHaveAttribute('title', reason!)
    expect(uploads).toBe(0)
    if (evidence) { await mkdir(evidence, { recursive: true }); await page.screenshot({ path: `${evidence}/${info.project.name}-${state}-attachments-blocked.png`, scale: 'css' }) }
  })
}

test('BOG UI statement line and account sheets preserve uncertain saves and keyboard recovery against Rails', async ({ page, context, request }, info) => {
  test.skip(!live || !api || !fixtures, 'Requires dedicated synthetic fixtures and local Rails')
  test.setTimeout(180_000)
  const fixture = fixtures.recovery[info.project.name]
  const authorization = `Bearer test_token:${fixture.clerk_id}:${fixture.email}:Ana:Fictional`
  await context.route(`${api}/**`, async route => {
    const headers = { ...route.request().headers(), Authorization: authorization }
    if (new URL(route.request().url()).pathname === '/api/v1/auth/me') {
      const response = await route.fetch({ headers }); const payload = await response.json()
      return route.fulfill({ response, json: { ...payload, user: { ...payload.user, clerk_id: 'e2e_participant' } } })
    }
    return route.continue({ headers })
  })
  if (info.project.name === 'desktop-chrome') await page.setViewportSize({ width: 1366, height: 900 })
  await page.goto(`${live}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Statements`)
  const review = page.getByRole('region', { name: 'Statement review' })
  await expect(review.getByRole('heading', { name: /1 line from Checking/ })).toBeVisible({ timeout: 60_000 })
  for (const kind of ['line', 'account']) {
    const keys: string[] = []
    const handler = async (route: import('@playwright/test').Route) => {
      keys.push(route.request().headers()['idempotency-key'])
      if (keys.length === 1) return route.fulfill({ status: 503, json: { errors: ['Connection interrupted.'] } })
      return route.fallback()
    }
    await context.route(`${api}/api/v1/document_imports/**/review/approve_lines`, handler)
    if (kind === 'line') {
      await review.getByRole('button', { name: 'Edit Fictional Market', exact: true }).click()
      await page.getByRole('dialog').getByLabel('Category').selectOption({ label: 'Groceries' })
    } else {
      await review.getByRole('button', { name: 'Change', exact: true }).click()
      await page.getByRole('dialog').getByLabel('Name', { exact: true }).fill('Fictional family checking account for our monthly spending')
    }
    const sheet = page.getByRole('dialog')
    await sheet.getByRole('button', { name: 'Save', exact: true }).click()
    await expect(sheet.getByRole('alert')).toContainText('Connection interrupted')
    const close = sheet.getByRole('button', { name: 'Close', exact: true })
    await expect(close).toBeEnabled()
    if (evidence) await page.screenshot({ path: `${evidence}/${info.project.name}-${kind}-recovery-sheet.png`, scale: 'css' })
    await close.focus()
    await page.keyboard.press('Shift+Tab')
    await expect(sheet).toContainText('Close this window to check whether your change saved or try it again.')
    await page.keyboard.press('Tab')
    await expect(close).toBeFocused()
    await page.keyboard.press('Escape')
    await expect(sheet).toHaveCount(0)
    const check = review.getByRole('button', { name: 'Check again', exact: true })
    await expect(check).toBeFocused()
    await page.keyboard.press('Enter')
    await expect(review).toContainText('No committed result found. Retry the exact saved request.')
    await expect(check).toBeFocused()
    await page.keyboard.press('Tab')
    const retry = review.getByRole('button', { name: 'Try again', exact: true })
    await expect(retry).toBeFocused()
    await page.keyboard.press('Enter')
    await expect(review.getByText('We’re not sure your last change saved.')).toHaveCount(0)
    expect(keys).toHaveLength(2)
    expect(keys[1]).toBe(keys[0])
    const persisted = await request.get(`${api}/api/v1/document_imports/${fixture.import_id}/source_review?revision_id=${fixture.revision_id}&page=1&per_page=50&filter=all`, { headers: { Authorization: authorization, 'X-Cohort-Id': String(fixture.cohort_id) } })
    expect(persisted.ok()).toBe(true)
    const saved = (await persisted.json()).source_review.participant_review
    if (kind === 'line') expect(saved.plan.done).toBe(1)
    else expect(saved.accounts[0].approved.tracked_account.label).toBe('Fictional family checking account for our monthly spending')
    await context.unroute(`${api}/api/v1/document_imports/**/review/approve_lines`, handler)
  }
})
