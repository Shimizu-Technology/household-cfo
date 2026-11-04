import { test, expect, type APIRequestContext } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { mkdir, writeFile } from 'node:fs/promises'
import path from 'node:path'

// Opt-in acceptance against an isolated real API, never the shared browser mocks.
const live = process.env.HCFO_W15_LIVE_URL
const api = process.env.HCFO_W15_API_URL ?? 'http://127.0.0.1:3215'
const fixtureFile = process.env.HCFO_W15_FIXTURE_FILE
const evidence = process.env.HCFO_W15_EVIDENCE_DIR
const fixture = fixtureFile ? JSON.parse(readFileSync(fixtureFile, 'utf8')) as {
  cohort_id: number; users: Record<string, { id: number; clerk_id: string; email: string }>
} : null

test('BOG UI budgetless challenge upload, one-tap review, patterns, goal and daily check-in', async ({ page, context, request }, info) => {
  test.skip(!live || !fixture, 'Requires W15 owned local API and synthetic challenge fixture')
  test.setTimeout(900_000)
  page.setDefaultTimeout(180_000)
  page.on('request', request => { if (request.url().startsWith(api) || request.url().includes('amazonaws.com')) console.log('W15 request', request.method(), new URL(request.url()).pathname) })
  page.on('requestfailed', request => console.log('W15 network failure', new URL(request.url()).pathname, request.failure()?.errorText))
  page.on('response', response => { if (response.url().startsWith(api) || response.url().includes('amazonaws.com')) console.log('W15 response', response.status(), new URL(response.url()).pathname) })
  const user = fixture!.users[info.project.name]
  const headers = { Authorization: `Bearer test_token:${user.clerk_id}:${user.email}:Ana:Fictional`, 'X-Cohort-Id': String(fixture!.cohort_id) }
  const read = async (client: APIRequestContext, route: string) => {
    const response = await client.get(`${api}/api/v1/${route}`, { headers })
    expect(response.ok(), await response.text()).toBeTruthy()
    return response.json()
  }
  await context.route(`${api}/**`, async route => {
    const outgoing = { ...route.request().headers(), Authorization: headers.Authorization }
    if (new URL(route.request().url()).pathname === '/api/v1/auth/me') {
      const response = await route.fetch({ headers: outgoing })
      const payload = await response.json()
      expect(payload.user.id).toBe(user.id)
      return route.fulfill({ response, json: { ...payload, user: { ...payload.user, clerk_id: 'e2e_participant' } } })
    }
    return route.continue({ headers: outgoing })
  })
  await context.route('https://**.amazonaws.com/**', async route => {
    const response = await route.fetch({ postData: readFileSync(path.resolve('../api/test/fixtures/files/documents/bank-of-guam-2026-10.pdf')) })
    if (!response.ok()) {
      const body = await response.text()
      console.log('W15 storage error', body.match(/<Code>(.*?)<\/Code>/)?.[1], body.match(/<Message>(.*?)<\/Message>/)?.[1])
    }
    await route.fulfill({ response, headers: { ...response.headers(), 'access-control-allow-origin': new URL(live!).origin } })
  })
  if (info.project.name === 'desktop-chrome') await page.setViewportSize({ width: 1366, height: 900 })
  const shot = async (name: string) => {
    if (!evidence) return
    await mkdir(`${evidence}/shots`, { recursive: true })
    await page.screenshot({ path: `${evidence}/shots/${info.project.name}-${name}.png`, fullPage: true })
    if (name === 'review') {
      await page.getByRole('list', { name: 'Lines that need a quick look' }).getByRole('listitem').first().scrollIntoViewIfNeeded()
      await page.screenshot({ path: `${evidence}/shots/${info.project.name}-review-viewport.png` })
    }
  }
  await page.goto(`${live}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Statements`)
  await expect(page.getByRole('heading', { name: 'Upload a statement', exact: true })).toBeVisible({ timeout: 180_000 })
  await shot('empty')
  const started = Date.now()
  const upload = page.waitForResponse(response => response.url() === `${api}/api/v1/document_imports/complete` && response.request().method() === 'POST')
  await page.locator('input[type=file]').first().setInputFiles(path.resolve('../api/test/fixtures/files/documents/bank-of-guam-2026-10.pdf'))
  const uploaded = await (await upload).json()
  expect(uploaded.document_import.id).toBeGreaterThan(0)
  const importId = uploaded.document_import.id as number
  const review = page.getByRole('region', { name: 'Statement review', exact: true })
  await expect(review).toContainText('27 lines', { timeout: 180_000 })
  await expect(review.getByRole('button', { name: /^Yes: Ross/ }).first()).toBeEnabled({ timeout: 180_000 })
  const readAt = Date.now()
  await shot('review')
  expect(await review.evaluate(element => element.scrollWidth > element.clientWidth + 1)).toBe(false)
  const decisions: string[] = []
  while (await review.getByRole('list', { name: 'Lines that need a quick look' }).count()) {
    const item = review.getByRole('list', { name: 'Lines that need a quick look' }).getByRole('listitem').first()
    const merchant = await item.locator('.statement-line-name').innerText()
    const yes = item.getByRole('button', { name: /^Yes:/ })
    // The synthetic participant treats groceries, fuel and bank fees as essentials;
    // restaurant meals and other purchases are everyday spending. Hints remain hers to confirm.
    const category = /payless|cost-u-less|shell|mobil|service fee/i.test(merchant) ? 'Bills & essentials' : 'Everyday spending'
    const chosenCategory = item.getByRole('button', { name: `${category}: ${merchant}`, exact: true })
    const choice = await yes.count() ? yes : chosenCategory
    await expect(choice).toBeEnabled({ timeout: 180_000 })
    const saved = page.waitForResponse(response => response.url().includes(`/document_imports/${importId}/review/approve_lines`) && response.request().method() === 'POST')
    await choice.click()
    const response = await saved
    expect(response.ok(), await response.text()).toBeTruthy()
    decisions.push(merchant)
    await expect(review.locator('.statement-exception .statement-line-name').filter({ hasText: new RegExp(`^${merchant.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`) })).toHaveCount(0, { timeout: 180_000 })
  }
  const rest = review.getByRole('button', { name: /^Approve (all|the other|it)/ })
  await expect(rest).toBeEnabled({ timeout: 180_000 })
  await rest.click()
  await expect(review).toContainText('All 27 lines are saved.', { timeout: 180_000 })
  await expect(page.getByText('Needs Review', { exact: true })).toHaveCount(0, { timeout: 180_000 })
  await shot('saved')
  const patternsResponse = page.waitForResponse(response => response.url().endsWith('/mia/messages') && response.request().method() === 'POST')
  await review.getByRole('button', { name: 'See what Mia notices', exact: true }).click()
  const patterns = await (await patternsResponse).json()
  const top = patterns.spending_patterns.discretionary_merchants.slice(0, 2).map((row: { label: string }) => row.label)
  expect(top).toHaveLength(2)
  expect(patterns.assistant_message.content).toContain(`${top[0]} or ${top[1]}?`)
  for (const merchant of top) expect(patterns.assistant_message.content).toContain(merchant)
  const amazon = patterns.spending_patterns.discretionary_merchants.find((row: { label: string }) => row.label === 'Amazon Marketplace')
  expect(amazon.total_cents).toBe(2600)
  const patternsAt = Date.now()
  await shot('patterns')
  if (evidence) await writeFile(`${evidence}/${info.project.name}-patterns-stage.json`, JSON.stringify({ started, readAt, patternsAt, uploadToReadMs: readAt - started, uploadToPatternsMs: patternsAt - started, patternsAnswer: patterns.assistant_message.content, patterns: patterns.spending_patterns }, null, 2))
  const document = (await read(request, `document_imports/${importId}`)).document_import
  expect(document.status).toBe('applied')
  expect(document.metadata.source_accounting_review_pending).toBe(false)
  const reviewState = await read(request, `document_imports/${importId}/source_review?revision_id=${document.metadata.source_accounting_revision_id}`)
  expect(reviewState.source_review.participant_review.categories.map((row: { name: string }) => row.name)).toEqual(['Bills & essentials', 'Everyday spending'])
  expect(reviewState.source_review.participant_review.plan.done).toBe(27)
  const send = async (message: string) => {
    const response = page.waitForResponse(response => response.url().endsWith('/mia/messages') && response.request().method() === 'POST')
    const input = page.getByRole('textbox', { name: 'Ask Mia', exact: true })
    await expect(input).toBeEnabled({ timeout: 180_000 })
    await input.fill(message)
    await page.getByRole('button', { name: 'Send message to Mia', exact: true }).click()
    const result = await response
    expect(result.ok(), await result.text()).toBeTruthy()
    return result.json()
  }
  await send(`I'll cut back on ${top[0]}`)
  const goal = page.getByRole('region', { name: 'Your challenge goal', exact: true })
  await goal.scrollIntoViewIfNeeded()
  await goal.getByRole('button', { name: 'Yes, set my goal to $500.00', exact: true }).click()
  await expect(goal).toContainText('Goal saved: $500.00')
  expect((await read(request, 'savings_challenge')).accepted_plan.target_cents).toBe(50_000)
  await goal.scrollIntoViewIfNeeded()
  await goal.getByRole('button', { name: 'Done', exact: true }).click()
  await send('Today I spent $6 at Jamba. I felt rushed when I bought it and now I feel calm.')
  const daily = page.getByRole('region', { name: 'Your check-in', exact: true })
  await expect(daily).toBeVisible({ timeout: 180_000 })
  await daily.scrollIntoViewIfNeeded()
  await daily.getByRole('button', { name: 'Save to today', exact: true }).click()
  await expect(daily).toContainText('Saved', { timeout: 180_000 })
  await shot('daily')
  const purchases = await read(request, 'savings_challenge/daily/records?collection=purchases')
  expect(purchases.records.length).toBe(1)
  expect(purchases.records[0].current_version).toMatchObject({ merchant: 'Jamba', amount_cents: 600 })
  const day = await read(request, 'savings_challenge/daily')
  expect(day.day.checked_in).toBe(true)
  if (evidence) await writeFile(`${evidence}/${info.project.name}-journey.json`, JSON.stringify({
    project: info.project.name, viewport: page.viewportSize(), importId, oneTapDecisions: decisions,
    uploadToReadMs: readAt - started, reviewMs: patternsAt - readAt, uploadToPatternsMs: patternsAt - started,
    patternsAnswer: patterns.assistant_message.content, patterns: patterns.spending_patterns, documentStatus: document.status, purchases, day,
  }, null, 2))
})
