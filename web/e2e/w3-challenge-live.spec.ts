import { expect as baseExpect, test, type APIRequestContext, type BrowserContext, type Page } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { mkdir, writeFile } from 'node:fs/promises'

// Local review runs share a heavily loaded host; wait for saved API outcomes.
const expect = baseExpect.configure({ timeout: 60_000 })
const live = process.env.HCFO_W3_LIVE_URL
const api = process.env.HCFO_W3_API_URL ?? 'http://127.0.0.1:3203'
const fixturePath = process.env.HCFO_W3_FIXTURE_FILE
const evidence = process.env.HCFO_W3_EVIDENCE_DIR
const fixture = fixturePath ? JSON.parse(readFileSync(fixturePath, 'utf8')) as { cohort_id: number; users: Record<string, { id: number; clerk_id: string; email: string }> } : null

type Participant = { id: number; clerk_id: string; email: string }
function participantHeaders(user: Participant) {
  return { Authorization: `Bearer test_token:${user.clerk_id}:${user.email}:Ana:Fictional`, 'X-Cohort-Id': String(fixture!.cohort_id) }
}
async function authorize(target: BrowserContext, user: Participant) {
  const headers = participantHeaders(user)
  await target.route(`${api}/**`, async route => {
    const outgoing = { ...route.request().headers(), Authorization: headers.Authorization }
    if (new URL(route.request().url()).pathname === '/api/v1/auth/me') {
      // Map the dev adapter alias to this project's real synthetic participant.
      const response = await route.fetch({ headers: outgoing })
      const payload = await response.json()
      expect(payload.user.id).toBe(user.id)
      return route.fulfill({ response, json: { ...payload, user: { ...payload.user, clerk_id: 'e2e_participant' } } })
    }
    return route.continue({ headers: outgoing })
  })
}
async function read(request: APIRequestContext, user: Participant, path: string) {
  const response = await request.get(`${api}/api/v1/${path}`, { headers: participantHeaders(user) })
  expect(response.ok(), await response.text()).toBe(true)
  return response.json()
}
async function send(target: Page, message: string, transcript: unknown[]) {
  const composer = target.getByRole('textbox', { name: 'Ask Mia', exact: true })
  await expect(composer).toBeEnabled({ timeout: 60_000 }); await composer.fill(message)
  const waiting = target.waitForResponse(response => response.url().endsWith('/api/v1/mia/messages') && response.request().method() === 'POST', { timeout: 60_000 })
  await target.getByRole('button', { name: 'Send message to Mia', exact: true }).click()
  const response = await waiting
  expect(response.status(), await response.text()).toBe(201)
  const payload = await response.json()
  transcript.push({ message, reply: payload.assistant_message.content })
  return payload
}

test.describe('BOG UI W3 real challenge journey', () => {
  test.skip(!live || !fixture, 'Needs the dedicated W3 synthetic Rails fixture; financial responses are never mocked.')
  test.setTimeout(600_000)
  test('join, patterns, reviewed goal, durable daily card and saved outcomes', async ({ page, context, browser, request }, info) => {
    test.skip(process.env.HCFO_W3_CHECKPOINT_PHASE === '1', 'Run on the Day 1 QA clock before the checkpoint phase.')
    const user = fixture!.users[info.project.name]
    const transcript: unknown[] = []
    await authorize(context, user)
    async function shot(target: Page, name: string) {
      if (evidence) {
        await mkdir(`${evidence}/shots`, { recursive: true })
        await target.screenshot({ path: `${evidence}/shots/${info.project.name}-${name}.png`, fullPage: true })
      }
      expect(await target.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    }
    if (info.project.name === 'desktop-chrome') await page.setViewportSize({ width: 1366, height: 900 })
    await page.goto(`${live}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Home`)
    const home = page.getByRole('region', { name: 'Savings challenge', exact: true })
    await expect(home).toBeVisible({ timeout: 60_000 })
    const before = await read(request, user, 'savings_challenge')
    if (!before.enrollment) {
      await expect(home).toContainText('cushion')
      await shot(page, 'join')
      await home.getByLabel(/accept joining the challenge/).check()
      if (await home.getByLabel(/start later than the group/).count()) await home.getByLabel(/start later than the group/).check()
      await home.getByRole('button', { name: 'Accept and join', exact: true }).click()
      await expect(home.getByRole('heading', { name: 'Set aside so far', exact: true })).toBeVisible()
    }
    await expect(page.locator('.tabs-today-action')).toHaveCount(0)
    await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()
    const patterns = await send(page, 'Can you identify spending patterns in my last 3 months?', transcript)
    expect(patterns.spending_patterns.coverage.months.map((row: { month: string }) => row.month)).toEqual(['2026-08', '2026-09', '2026-10'])
    expect(patterns.spending_patterns.coverage.account_completeness).toBe('unknown')
    expect(patterns.assistant_message.content).toMatch(/comfortable|feel better/i)
    expect(patterns.assistant_message.content).not.toMatch(/Ross.{0,50}subscription|Only confirmed purchases|Reviewed linked refunds/)
    await shot(page, 'patterns')
    const merchant = patterns.spending_patterns.candidate_changes[0].merchant
    await send(page, `I'll cut back on ${merchant}`, transcript)
    const goal = page.getByRole('region', { name: 'Your challenge goal', exact: true })
    await expect(goal).toContainText('$500.00 over your 90 days?')
    await goal.scrollIntoViewIfNeeded()
    await shot(page, 'goal-review')
    await goal.getByRole('button', { name: 'Yes, set my goal to $500.00', exact: true }).click()
    await expect(goal).toContainText('Goal saved: $500.00')
    expect((await read(request, user, 'savings_challenge')).accepted_plan.target_cents).toBe(50000)
    await goal.getByRole('button', { name: 'Done', exact: true }).click()
    await send(page, "Let's do $400 instead", transcript)
    await shot(page, 'goal-change')
    await goal.getByRole('button', { name: 'Yes, set my goal to $400.00', exact: true }).click()
    await expect(goal).toContainText('Goal saved: $400.00')
    expect((await read(request, user, 'savings_challenge')).accepted_plan.target_cents).toBe(40000)
    await goal.getByRole('button', { name: 'Done', exact: true }).click()
    const debt = await send(page, 'I joined to pay down my credit card, how does this help?', transcript)
    expect(debt.assistant_message.content).toContain('Optional card & debt review in Savings')
    await shot(page, 'debt')
    const purchasesBefore = await read(request, user, 'savings_challenge/daily/records?collection=purchases')
    const reply = await send(page, 'Today I spent $14.75 at Kmart on snacks for the kids. I felt rushed when I bought it and now I feel guilty.', transcript)
    expect(reply.assistant_message.content).toContain('Being rushed')
    expect((await read(request, user, 'savings_challenge/daily/records?collection=purchases')).records.length).toBe(purchasesBefore.records.length)
    await page.getByRole('region', { name: 'Your check-in', exact: true }).scrollIntoViewIfNeeded()
    await shot(page, 'daily-draft')
    // A genuinely new context has neither sessionStorage nor the old in-memory card store.
    const fresh = await browser.newContext({ viewport: page.viewportSize()!, isMobile: info.project.use.isMobile as boolean, hasTouch: info.project.use.hasTouch as boolean, deviceScaleFactor: info.project.use.deviceScaleFactor as number })
    try {
      await authorize(fresh, user)
      const restored = await fresh.newPage()
      await restored.goto(`${live}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Ask%20Mia`)
      const card = restored.getByRole('region', { name: 'Your check-in', exact: true })
      await expect(card).toBeVisible({ timeout: 60_000 })
      await expect(card.getByLabel('Amount for Kmart', { exact: true })).toHaveValue('14.75')
      await expect(card.getByLabel('How did you feel when you spent?', { exact: true })).toHaveValue('rushed')
      await card.scrollIntoViewIfNeeded()
      await shot(restored, 'daily-restored-fresh-context')
      const save = card.getByRole('button', { name: 'Save to today', exact: true })
      await expect(save).toBeEnabled(); await save.click()
      await expect(card).toContainText('Saved to today', { timeout: 60_000 })
      const purchases = await read(request, user, 'savings_challenge/daily/records?collection=purchases')
      expect(purchases.records.length).toBe(purchasesBefore.records.length + 1)
      expect(purchases.records.at(-1).current_version).toMatchObject({ merchant: 'Kmart', amount_cents: 1475 })
      const reflections = await read(request, user, 'savings_challenge/daily/records?collection=reflections')
      expect(reflections.records.at(-1).current_version.feeling_then).toBe('rushed')
      expect((await read(request, user, 'savings_challenge/daily')).day.checked_in).toBe(true)
      await shot(restored, 'daily-saved')
      await restored.reload()
      await expect(restored.getByRole('textbox', { name: 'Ask Mia', exact: true })).toBeEnabled()
      expect((await read(request, user, 'savings_challenge/chat_cards')).records).toEqual([])
      expect((await read(request, user, 'savings_challenge/daily/records?collection=purchases')).records.length).toBe(purchases.records.length)
      await restored.getByRole('link', { name: 'Savings', exact: true }).click()
      await expect(restored.getByRole('region', { name: 'Your 90 days', exact: true })).toBeVisible()
      const strip = restored.getByRole('region', { name: 'Your 90 days', exact: true })
      await expect(strip.getByRole('list', { name: 'Day symbols' })).toBeVisible()
      if (restored.viewportSize()!.width >= 768) {
        await expect(strip.getByText('Swipe for all 90 days')).toBeHidden()
        expect(await strip.locator('.challenge-days').evaluate(element => element.scrollWidth <= element.clientWidth)).toBe(true)
      } else await expect(strip.getByText('Swipe for all 90 days')).toBeVisible()
      await shot(restored, 'home-strip')
      await restored.getByRole('button', { name: /Day 1,.*Checked in/ }).click()
      const today = restored.getByRole('dialog', { name: 'Today', exact: true })
      await expect(today).toBeVisible()
      await today.getByRole('button', { name: 'Checkpoints', exact: true }).click()
      await expect(today.getByRole('button', { name: 'Checkpoints', exact: true })).toHaveAttribute('aria-pressed', 'true')
      await expect(today).toContainText('Look back at your first 30 days')
      await shot(restored, 'today-checkpoints')
      await today.getByRole('button', { name: 'Close Today', exact: true }).click()
      transcript.push({ approvedTarget: (await read(request, user, 'savings_challenge')).accepted_plan.target_cents, purchases: purchases.records, reflections: reflections.records })
    } finally { await fresh.close() }
    if (evidence) await writeFile(`${evidence}/${info.project.name}-transcript.json`, JSON.stringify(transcript, null, 2))
  })
  test('Day 30 review, no-spend day and deposit are visible and saved', async ({ page, context, request }, info) => {
    test.skip(process.env.HCFO_W3_CHECKPOINT_PHASE !== '1', 'Requires the Day 30 QA clock after the joined fixture journey.')
    const user = fixture!.users[info.project.name]
    const transcript: unknown[] = []
    await authorize(context, user)
    async function shot(name: string) {
      await page.evaluate(() => window.scrollTo(0, 0))
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
      if (evidence) await page.screenshot({ path: `${evidence}/shots/${info.project.name}-${name}.png`, fullPage: (await page.getByRole('dialog').count()) === 0 })
    }
    if (info.project.name === 'desktop-chrome') await page.setViewportSize({ width: 1366, height: 900 })
    await page.goto(`${live}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Home`)
    const home = page.getByRole('region', { name: 'Savings challenge', exact: true })
    await expect(home).toBeVisible({ timeout: 60_000 })
    const initial = await read(request, user, 'savings_challenge')
    const checkpointAlreadySaved = !initial.timeline.checkpoints_due.includes(30)
    if (!checkpointAlreadySaved) await expect(home.getByRole('button', { name: 'Day 30 ready to review', exact: true })).toBeVisible()
    await shot(checkpointAlreadySaved ? 'day30-already-reviewed' : 'day30-ready')
    await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()
    const answer = await send(page, 'What spending patterns do you see in my last 3 months?', transcript)
    expect(answer.spending_patterns.possible_subscriptions.map((row: { merchant: string }) => row.merchant)).toEqual(['Stream service'])
    transcript.push({ patterns: answer.spending_patterns, reply: answer.assistant_message.content })
    await shot('patterns-final')
    await page.getByRole('link', { name: 'Savings', exact: true }).click()
    if (initial.projection.reported_cents === null) {
      await home.getByRole('button', { name: /^I set money aside/ }).click()
      await home.getByLabel('Amount in US dollars', { exact: true }).fill('50.00')
      await home.getByRole('button', { name: 'Review savings record', exact: true }).click()
      const confirm = home.getByRole('button', { name: /^Confirm \$50.00 set aside/ })
      await expect(confirm).toBeEnabled(); await confirm.click()
      await expect(home.getByRole('article', { name: 'Approved savings progress' })).toContainText('$50.00')
    }
    expect((await read(request, user, 'savings_challenge')).projection.reported_cents).toBe(5000)
    await home.getByRole('button', { name: /Day 30,.*\$50.00 set aside/ }).click()
    const today = page.getByRole('dialog', { name: 'Today', exact: true })
    await expect(today).toBeVisible()
    if ((await read(request, user, 'savings_challenge/daily')).day.spending_state !== 'no_spend') {
      await today.getByRole('combobox', { name: 'How was this day?', exact: true }).selectOption('no_spend')
      await today.getByRole('button', { name: 'Save day', exact: true }).click()
    }
    await expect(today).toContainText('Saved as a no-spend day.', { timeout: 30_000 })
    await today.getByRole('button', { name: 'Close Today', exact: true }).click()
    await expect(home.getByRole('button', { name: /Day 30,.*No spending; \$50.00 set aside/ })).toBeVisible()
    await shot('day30-deposit-and-no-spend')
    if (checkpointAlreadySaved) {
      await home.getByRole('button', { name: /Day 30,.*No spending/ }).click()
      await today.getByRole('button', { name: 'Checkpoints', exact: true }).click()
    } else await home.getByRole('button', { name: 'Day 30 ready to review', exact: true }).click()
    await expect(today.getByRole('button', { name: 'Checkpoints', exact: true })).toHaveAttribute('aria-pressed', 'true')
    await expect(today).toContainText('Look back at your first 30 days')
    await expect(today.getByRole('button', { name: 'Checkpoints', exact: true })).toHaveCSS('white-space', 'nowrap')
    await shot('day30-checkpoint-intro')
    if (!checkpointAlreadySaved) {
      await today.getByRole('button', { name: /^Review Day 30/ }).click()
      await today.getByRole('checkbox', { name: /Prepare this exact milestone/ }).check()
      await today.getByRole('button', { name: 'Save Day 30 checkpoint preview', exact: true }).click()
      await today.getByRole('checkbox', { name: /I reviewed this exact as-of date/ }).check()
      const committed = page.waitForResponse(response => response.url().endsWith('/daily/actions/checkpoint_approve') && response.request().method() === 'POST')
      await today.getByRole('button', { name: 'Approve Day 30 checkpoint', exact: true }).click()
      expect((await committed).ok()).toBe(true)
    }
    await expect(today.getByText(/Approved version 1/)).toBeVisible()
    const checkpoints = await read(request, user, 'savings_challenge/daily/records?collection=checkpoints')
    expect(checkpoints.records.find((row: { milestone_day: number }) => row.milestone_day === 30).current_version.snapshot.savings.reported_cents).toBe(5000)
    await shot('day30-checkpoint-saved')
    await today.getByRole('button', { name: 'Close Today', exact: true }).click()
    await expect(home.getByRole('button', { name: 'Day 30 ready to review', exact: true })).toHaveCount(0)
    await home.getByText('Your records & corrections', { exact: true }).click()
    await home.getByText('Review or fix this record', { exact: true }).click()
    await expect(home.getByRole('button', { name: /^Fix the \$50.00 set aside/ })).toBeVisible()
    await shot('compact-savings-record')
    await page.getByRole('button', { name: 'Privacy & reminders', exact: true }).click()
    const privacy = page.getByRole('dialog', { name: 'Privacy & reminders', exact: true })
    await expect(privacy).toContainText('Your records start private.')
    await expect(privacy.getByText('Sharing choices', { exact: false })).toBeVisible({ timeout: 30000 })
    await shot('privacy-short')
    transcript.push({ challenge: await read(request, user, 'savings_challenge'), checkpoints, day: await read(request, user, 'savings_challenge/daily') })
    if (evidence) await writeFile(`${evidence}/${info.project.name}-day30-transcript.json`, JSON.stringify(transcript, null, 2))
  })

  test('recovery boundaries for loading, handoff, clear chat and replaced goal', async ({ page, context, request }, info) => {
    test.skip(process.env.HCFO_W3_RECOVERY_PHASE !== '1', 'Run after the Day 30 phase against the dedicated fixture.')
    if (info.project.name === 'desktop-chrome') await page.setViewportSize({ width: 1366, height: 900 })
    const user = fixture!.users[info.project.name]
    const transcript: unknown[] = []
    await authorize(context, user)
    const url = `${live}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Ask%20Mia`
    async function clearChat() {
      const header = page.locator('.chat-shell-header')
      const more = header.getByRole('button', { name: 'More chat options', exact: true })
      if (await more.isVisible()) { await more.click(); await page.locator('.chat-more-menu').getByRole('button', { name: 'Clear chat', exact: true }).click() }
      else await header.getByRole('button', { name: 'Clear', exact: true }).click()
      const cleared = page.waitForResponse(response => response.url().endsWith('/mia/messages') && response.request().method() === 'DELETE')
      await page.getByRole('dialog', { name: 'Clear this chat?', exact: true }).getByRole('button', { name: 'Clear chat', exact: true }).click()
      expect((await cleared).ok()).toBe(true)
    }
    await page.goto(url)
    await expect(page.getByRole('textbox', { name: 'Ask Mia', exact: true })).toBeEnabled({ timeout: 60000 })
    await clearChat()
    await send(page, 'Set my goal to $500', transcript)
    const stale = await context.newPage()
    try {
      await stale.goto(url)
      const oldGoal = stale.getByRole('region', { name: 'Your challenge goal', exact: true })
      await expect(oldGoal).toContainText('$500.00', { timeout: 60000 })
      await send(page, 'Can we change my goal to $300?', transcript)
      const goal = page.getByRole('region', { name: 'Your challenge goal', exact: true })
      await expect(goal).toContainText('$300.00')
      await oldGoal.getByRole('button', { name: 'Yes, set my goal to $500.00', exact: true }).click()
      await expect(oldGoal.getByRole('alert')).toBeVisible()
      await expect(oldGoal).not.toContainText('Goal saved:')
      await goal.getByRole('button', { name: 'Yes, set my goal to $300.00', exact: true }).click()
      await expect(goal).toContainText('Goal saved: $300.00', { timeout: 60000 })
      expect((await read(request, user, 'savings_challenge')).accepted_plan.target_cents).toBe(30000)
      await goal.getByRole('button', { name: 'Done', exact: true }).click()
      await send(page, 'Please set my target to $400 instead of $500.', transcript)
      await goal.getByRole('button', { name: 'Yes, set my goal to $400.00', exact: true }).click()
      await expect(goal).toContainText('Goal saved: $400.00', { timeout: 60000 })
      await goal.getByRole('button', { name: 'Done', exact: true }).click()
    } finally { await stale.close() }
    const before = (await read(request, user, 'savings_challenge/daily/records?collection=purchases')).records.length
    await send(page, 'Yesterday I spent $9 at Shell. I felt rushed when I bought it and now I feel guilty.', transcript)
    const card = page.getByRole('region', { name: 'Your check-in', exact: true })
    await expect(card).toBeVisible({ timeout: 30000 })
    let release!: () => void
    const gate = new Promise<void>(resolve => { release = resolve })
    await page.route(`${api}/api/v1/savings_challenge/chat_cards`, async route => { await gate; await route.fallback() })
    await page.reload()
    await expect(page.getByRole('textbox', { name: 'Ask Mia', exact: true })).toBeEnabled({ timeout: 60000 })
    await expect(card).toHaveCount(0)
    release()
    await expect(card).toBeVisible({ timeout: 60000 })
    await card.getByRole('button', { name: 'Edit in Today', exact: true }).click()
    const today = page.getByRole('dialog', { name: 'Today', exact: true })
    await expect(today.getByLabel('Where did you buy it?')).toHaveValue('Shell', { timeout: 60000 })
    expect((await read(request, user, 'savings_challenge/chat_cards')).records).toHaveLength(1)
    if (evidence) {
      await mkdir(`${evidence}/shots`, { recursive: true })
      await page.screenshot({ path: `${evidence}/shots/${info.project.name}-today-handoff.png`, fullPage: true })
    }
    // Closing Today before approval must retain the exact editable purchase.
    await today.getByRole('button', { name: 'Close Today', exact: true }).click()
    await page.reload()
    await expect(card.getByLabel('Amount for Shell', { exact: true })).toHaveValue('9.00', { timeout: 60000 })
    if (evidence) {
      await card.getByLabel('Amount for Shell', { exact: true }).scrollIntoViewIfNeeded()
      await page.screenshot({ path: `${evidence}/shots/${info.project.name}-recovered-handoff.png`, fullPage: true })
    }
    await card.getByRole('button', { name: 'Edit in Today', exact: true }).click()
    await expect(today.getByLabel('Where did you buy it?')).toHaveValue('Shell', { timeout: 60000 })
    await today.getByRole('button', { name: 'Save purchase', exact: true }).click()
    await expect(today.getByRole('button', { name: 'Correct Shell', exact: true })).toBeVisible({ timeout: 60000 })
    await today.getByRole('button', { name: 'Close Today', exact: true }).click()
    await page.reload()
    await expect(page.getByRole('textbox', { name: 'Ask Mia', exact: true })).toBeEnabled({ timeout: 60000 })
    await expect(card).toContainText('Almost done', { timeout: 60000 })
    if (evidence) {
      await card.getByRole('button', { name: 'Save', exact: true }).scrollIntoViewIfNeeded()
      await page.screenshot({ path: `${evidence}/shots/${info.project.name}-saved-in-today.png`, fullPage: true })
    }
    const finish = card.getByRole('button', { name: 'Save', exact: true })
    await expect(finish).toBeEnabled(); await finish.click()
    // This final step serializes the check-in, private reflection and card-state
    // writes against the real API. Allow the loaded QA host to finish them.
    await expect(card).toContainText('Saved', { timeout: 180000 })
    await card.getByRole('button', { name: 'Done', exact: true }).click()
    await page.reload()
    await expect(card).toHaveCount(0)
    expect((await read(request, user, 'savings_challenge/daily/records?collection=purchases')).records.length).toBe(before + 1)
    await send(page, 'Yesterday I spent $6 at Payless. I felt worried when I bought it and now I feel calm.', transcript)
    await expect(card).toBeVisible({ timeout: 30000 })
    await clearChat()
    await expect(card).toHaveCount(0)
    expect((await read(request, user, 'savings_challenge/chat_cards')).records).toEqual([])
    expect(await page.evaluate(() => Object.keys(sessionStorage).filter(key => key.includes('mia-daily-cards')).map(key => sessionStorage.getItem(key)))).toEqual([])
    await page.reload()
    await expect(page.getByRole('textbox', { name: 'Ask Mia', exact: true })).toBeEnabled({ timeout: 60000 })
    await expect(card).toHaveCount(0)
    if (evidence) await writeFile(`${evidence}/${info.project.name}-recovery-transcript.json`, JSON.stringify(transcript, null, 2))
  })

})
