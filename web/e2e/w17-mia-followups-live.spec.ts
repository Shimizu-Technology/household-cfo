import { expect, test, type Page } from '@playwright/test'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'

// Synthetic worker DB only. Provider is disabled in the local API; the bounded
// live narrator cases are recorded separately so browser retries cannot spend.
const enabled = process.env.HCFO_W17_LIVE_API === '1'
const api = 'http://127.0.0.1:3217/api/v1'
const app = 'http://127.0.0.1:5317'
const evidence = process.env.HCFO_W17_EVIDENCE ?? '/tmp/codex-r4-w17-evidence'
const fixture = enabled ? JSON.parse(readFileSync('/tmp/codex-r4-w17-fixture.json', 'utf8')) : {}
const auth = (cohort: number) => ({ Authorization: 'Bearer test_token:e2e_participant:participant@pilot.test:Ana:Santos', 'X-Cohort-Id': String(cohort) })

async function open(page: Page, cohort: number) {
  await page.addInitScript(id => localStorage.setItem('household-cfo:participant-program:v2:e2e_participant:901', String(id)), cohort)
  await page.goto(`${app}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Ask%20Mia`)
  await expect(page.getByRole('textbox', { name: 'Ask Mia', exact: true })).toBeEnabled()
}
async function send(page: Page, message: string) {
  const input = page.getByRole('textbox', { name: 'Ask Mia', exact: true })
  await expect(input).toBeEnabled()
  await input.fill(message)
  const reply = page.waitForResponse(response => response.url().endsWith('/api/v1/mia/messages') && response.request().method() === 'POST', { timeout: 90_000 })
  await page.getByRole('button', { name: 'Send message to Mia', exact: true }).click()
  const response = await reply
  expect(response.status()).toBe(201)
  const body = await response.json()
  await expect(input).toBeEnabled()
  return body
}
async function shot(page: Page, name: string) {
  mkdirSync(evidence, { recursive: true })
  await page.screenshot({ path: `${evidence}/${name}.png`, fullPage: false })
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
}

test.describe('BOG UI W17 Mia follow-ups against real Rails', () => {
  test.skip(!enabled, 'Requires W17 isolated synthetic stack and fixture')
  test.setTimeout(300_000)

  test('monthly answer and a fresh purchase agree with both review cards and saved spending', async ({ page, request }, info) => {
    if (info.project.name === 'desktop-chrome') await page.setViewportSize({ width: 1366, height: 900 })
    await open(page, fixture.household_cohort)
    await shot(page, `${info.project.name}-household-empty`)
    const before = await (await request.get(`${api}/workspace`, { headers: auth(fixture.household_cohort) })).json()
    const pendingCount = before.budget.annual_plan.pending_transaction_drafts_meta.total_count
    const month = await send(page, 'How am I doing this month?')
    if (pendingCount > 0) expect(month.assistant_message.content).toContain(`Review the ${pendingCount} purchases waiting`)
    else expect(month.month_answer.pending_review_count).toBe(0)
    expect(month.assistant_message.content).not.toContain('confirmed category spending')
    const purchase = await send(page, 'I spent $18.47 at Payless on groceries today')
    const fresh = purchase.transaction_draft
    expect(fresh.amount_cents).toBe(1847)
    expect(purchase.assistant_message.content).toContain('$18.47')
    expect(purchase.budget.annual_plan.pending_transaction_drafts[0].id).toBe(fresh.id)
    const card = page.locator(`[data-review-item="${fresh.id}"]`)
    await expect(page.locator('.transaction-draft-card').first()).toHaveAttribute('data-review-item', String(fresh.id))
    await expect(card.locator('.mia-change-figure')).toHaveText('$18.47')
    await card.locator('.mia-change-headline').scrollIntoViewIfNeeded()
    await shot(page, `${info.project.name}-chat-purchase`)
    await card.getByRole('button', { name: /^Change Payless/ }).click()
    const longMerchant = `Payless ${info.project.name} — household groceries and supplies for the family and visiting relatives`
    await card.getByLabel('Merchant', { exact: true }).fill(longMerchant)
    const updated = page.waitForResponse(response => response.url().endsWith(`/transaction_drafts/${fresh.id}`) && response.request().method() === 'PATCH', { timeout: 90_000 })
    await card.getByRole('button', { name: 'Save draft', exact: true }).click()
    expect((await updated).ok()).toBe(true)
    await expect(card.locator('.mia-change-headline')).toContainText(longMerchant)
    await card.locator('.mia-change-headline').scrollIntoViewIfNeeded()
    await shot(page, `${info.project.name}-chat-long-purchase`)
    // The same saved card appears in the Review destination.
    await page.goto(`${app}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Review`)
    const reviewCard = page.locator(`[data-review-item="${fresh.id}"]`)
    await expect(reviewCard.locator('.mia-change-figure')).toHaveText('$18.47')
    await reviewCard.locator('.mia-change-headline').scrollIntoViewIfNeeded()
    await shot(page, `${info.project.name}-review-long-purchase`)
    const confirm = page.waitForResponse(response => response.url().endsWith(`/transaction_drafts/${fresh.id}/confirm`), { timeout: 90_000 })
    await reviewCard.getByRole('button', { name: /^Confirm / }).click()
    expect((await confirm).ok()).toBe(true)
    const after = await (await request.get(`${api}/workspace`, { headers: auth(fixture.household_cohort) })).json()
    expect(after.budget.annual_plan.pending_transaction_drafts.some((draft: { id: number }) => draft.id === fresh.id)).toBe(false)
    expect(after.budget.annual_plan.recent_transactions).toContainEqual(expect.objectContaining({ merchant: longMerchant, amount: 18.47 }))
    writeFileSync(`${evidence}/${info.project.name}-household-results.json`, JSON.stringify({ month, purchase, after }, null, 2))
  })

  test('patterns and both replacement amounts persist only after confirmation', async ({ page, request }, info) => {
    if (info.project.name === 'desktop-chrome') await page.setViewportSize({ width: 1366, height: 900 })
    await open(page, fixture.challenge_cohort)
    const patterns = await send(page, 'What spending patterns do you see?')
    expect(patterns.assistant_message.content).toContain('I only see purchases for Oct:')
    await shot(page, `${info.project.name}-patterns`)
    const first = await send(page, 'Change my goal from $500 to 300')
    expect(first.challenge_chat_card.input.target_cents).toBe(30000)
    const card = page.getByRole('region', { name: 'Your challenge goal' })
    await expect(card).toContainText('$300')
    await shot(page, `${info.project.name}-goal-300`)
    await card.getByRole('button', { name: 'Yes, set my goal to $300', exact: true }).click()
    await expect(card.getByRole('heading', { name: 'Goal saved: $300', exact: true })).toBeVisible({ timeout: 60_000 })
    const second = await send(page, 'I want my goal to be $500 instead of $400')
    expect(second.challenge_chat_card.input.target_cents).toBe(50000)
    await expect(card).toContainText('$500')
    await shot(page, `${info.project.name}-goal-500`)
    await card.getByRole('button', { name: 'Yes, set my goal to $500', exact: true }).click()
    await expect(card.getByRole('heading', { name: 'Goal saved: $500', exact: true })).toBeVisible({ timeout: 60_000 })
    const after = await (await request.get(`${api}/savings_challenge`, { headers: auth(fixture.challenge_cohort) })).json()
    writeFileSync(`${evidence}/${info.project.name}-challenge-results.json`, JSON.stringify({ patterns, first, second, after }, null, 2))
    expect(after.accepted_plan.target_cents).toBe(50000)
  })

  test('Not now and the empty review leave approved purchases unchanged', async ({ page, request }, info) => {
    if (info.project.name === 'desktop-chrome') await page.setViewportSize({ width: 1366, height: 900 })
    await open(page, fixture.household_cohort)
    const before = await (await request.get(`${api}/workspace`, { headers: auth(fixture.household_cohort) })).json()
    const reply = await send(page, 'I spent $12.34 at Kmart on groceries today')
    const id = reply.transaction_draft.id
    const card = page.locator(`[data-review-item="${id}"]`)
    const ignored = page.waitForResponse(response => response.url().endsWith(`/transaction_drafts/${id}/ignore`), { timeout: 90_000 })
    await card.getByRole('button', { name: /^Not now / }).click()
    expect((await ignored).ok()).toBe(true)
    await page.goto(`${app}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Review`)
    const stack = page.locator('.transaction-draft-stack')
    if (await stack.getByRole('checkbox', { name: 'Select this page' }).count()) {
      await stack.getByRole('checkbox', { name: 'Select this page' }).check()
      await stack.getByText('More bulk options', { exact: true }).click()
      await stack.getByRole('button', { name: /^Ignore all \d+/ }).click()
      await page.getByRole('alertdialog', { name: 'Ignore these purchases?' }).getByRole('button', { name: 'Ignore them', exact: true }).click()
    }
    await expect(stack.getByRole('status').filter({ hasText: /^All caught up$/ })).toBeVisible({ timeout: 60_000 })
    const after = await (await request.get(`${api}/workspace`, { headers: auth(fixture.household_cohort) })).json()
    expect(after.budget.annual_plan.pending_transaction_drafts).toEqual([])
    expect(after.budget.annual_plan.recent_transactions).toEqual(before.budget.annual_plan.recent_transactions)
    await shot(page, `${info.project.name}-review-empty`)
    await page.goto(`${app}/?pilot_e2e_role=participant&pilot_e2e_live_api=true#Ask%20Mia`)
    await expect(page.getByRole('textbox', { name: 'Ask Mia', exact: true })).toBeEnabled()
    await shot(page, `${info.project.name}-chat-no-purchases`)
    writeFileSync(`${evidence}/${info.project.name}-dismiss-results.json`, JSON.stringify({ before, reply, after }, null, 2))
  })
})
