import { expectPhoneGroundCoverage } from './helpers/shellGround'
import { expect, test, type Page } from '@playwright/test'
import { mkdir } from 'node:fs/promises'
import workspace from './fixtures/savings-home-workspace.json' with { type: 'json' }
import { savingsFixture, savingsPlanVersion } from '../src/test/savingsFixtures'
import { dailyContext, dailyVersion } from '../src/test/dailyFixtures'

// Synthetic Rails workspace captured from an isolated, system-sealed savings cohort.
// Every endpoint remains observable; no private read is silently supplied by a cache.
async function mockSavingsHome(page: Page, checkedIn = false, notOpen = false) {
  const challenge = { ...savingsFixture(), cohort_id: 1, accepted_plan: savingsPlanVersion() }
  challenge.enrollment!.cohort_id = 1
  challenge.enrollment!.current_accepted_plan_version_id = 21
  const actor = { user_id: 901, household_id: 1 }
  await page.route('http://api.test/api/**', route => {
    const url = new URL(route.request().url())
    const path = url.pathname
    if (path === '/api/public/brand') return route.fulfill({ json: { brand: workspace.workspace.brand.config, available: true, source: 'legacy_household_cfo_default', workspace: null, version: null, primary_domain: '127.0.0.1' } })
    if (path === '/api/v1/auth/me') return route.fulfill({ json: { user: { id: 901, clerk_id: 'e2e_participant', email: 'participant@pilot.test', first_name: 'Test', last_name: 'Participant', full_name: 'Test Participant', role: 'participant', is_participant: true, is_staff: false, is_admin: false, is_coach: false, invitation_status: 'accepted', coach_workspaces: [], active_coach_workspace: null } } })
    if (path === '/api/v1/workspace') return route.fulfill({ json: notOpen ? { ...workspace, workspace: { ...workspace.workspace, challenge_open: false, challenge_state: 'not_open' } } : workspace })
    if (path === '/api/v1/document_imports') return route.fulfill({ json: { document_imports: [] } })
    if (path === '/api/v1/savings_challenge/chat_cards') return route.fulfill({ json: { records: [], actor_scope: actor, cohort_id: 1, enrollment_id: 1 } })
    if (path === '/api/v1/savings_challenge') return route.fulfill({ json: challenge })
    if (path === '/api/v1/savings_challenge/daily') return route.fulfill({ json: { ...dailyContext, day: { ...dailyContext.day, local_on: challenge.calendar!.local_today, check_in_id: checkedIn ? 7 : null, check_in_version_id: checkedIn ? 8 : null, spending_state: checkedIn ? 'spending' : 'unknown', approved_purchase_count: checkedIn ? 1 : 0, reported_spend_cents: checkedIn ? 1250 : null, completed_at: checkedIn ? '2026-10-04T01:00:00Z' : null }, actor_scope: actor, cohort_id: 1, enrollment_id: 1, calendar: challenge.calendar } })
    if (path === '/api/v1/savings_challenge/daily/records') return route.fulfill({ json: { actor_scope: actor, cohort_id: 1, enrollment_id: 1, records: checkedIn && url.searchParams.get('collection') === 'purchases' ? [{ id: 200, lock_version: 0, current_version_id: dailyVersion.id, current_version: { ...dailyVersion, purchased_on: challenge.calendar!.local_today } }] : [], next_cursor: null } })
    if (/\/savings_challenge\/(entry_drafts|entries|plan_drafts|entry_versions)$/.test(path)) return route.fulfill({ json: { actor_scope: actor, cohort_id: 1, enrollment_id: 1, records: [], next_cursor: null } })
    return route.fulfill({ status: 404, json: { errors: ['Unexpected fixture read'] } })
  })
}

test('BOG UI an unopened challenge explains why statements cannot be uploaded', async ({ page }, info) => {
  await mockSavingsHome(page, false, true)
  if (info.project.name === 'desktop-chrome') await page.setViewportSize({ width: 1366, height: 900 })
  await page.goto('/?pilot_e2e_role=participant#Statements')
  const imports = page.getByRole('region', { name: 'Private financial document imports' })
  await expect(imports).toContainText('Your coach is still setting up your program. You can upload statements once it opens.')
  await expect(imports.locator('input[type=file]').first()).toBeDisabled()
  await expect(imports.getByText('Unavailable right now').first()).toBeVisible()
  if (process.env.HCFO_W14_EVIDENCE_DIR) {
    await mkdir(process.env.HCFO_W14_EVIDENCE_DIR, { recursive: true })
    await page.screenshot({ path: `${process.env.HCFO_W14_EVIDENCE_DIR}/${info.project.name}-unopened.png`, fullPage: true })
  }
})

async function openDetails(page: Page, label: string | RegExp) {
  const summary = page.locator('details > summary').filter({ hasText: label })
  await summary.scrollIntoViewIfNeeded()
  await page.evaluate(() => document.fonts.ready)
  await summary.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  await summary.click()
  await expect(summary.locator('..')).toHaveAttribute('open', '')
}

test('BOG UI savings Home loads each read once and opens hidden histories on demand in compact phone layouts', async ({ page }) => {
  const reads: string[] = []
  page.on('request', request => {
    if (request.method() === 'GET' && request.url().startsWith('http://api.test/api/v1/')) reads.push(new URL(request.url()).pathname)
  })
  await mockSavingsHome(page)
  await page.goto('/?pilot_e2e_role=participant#Home')
  const home = page.getByRole('region', { name: 'Savings challenge', exact: true })
  await expect(home.getByRole('article', { name: 'Approved savings progress' })).toBeVisible()
  await expect.poll(() => reads.filter(path => path.endsWith('/daily')).length).toBe(1)
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  expect(reads.filter(path => path.startsWith('/api/v1/savings_challenge')).sort()).toEqual(['/api/v1/savings_challenge', '/api/v1/savings_challenge/chat_cards', '/api/v1/savings_challenge/daily'])
  expect(reads.filter(path => path === '/api/v1/workspace')).toHaveLength(1)
  expect(reads.filter(path => /document_imports|spending_report|mia\/messages/.test(path))).toEqual([])
  await home.getByRole('button', { name: /^I set money aside/ }).click()
  await expect.poll(() => reads.filter(path => path.endsWith('/entry_drafts')).length).toBe(1)
  await openDetails(page, /^Your records & corrections/)
  await expect(home.getByRole('region', { name: 'Savings history', exact: true })).not.toContainText('Loading savings history…')
  expect(reads.filter(path => path.endsWith('/entries'))).toHaveLength(1)
  expect(reads.filter(path => path.endsWith('/entry_versions'))).toHaveLength(0)
  await openDetails(page, 'Earlier versions of your records')
  await expect(home.getByRole('region', { name: 'Earlier versions', exact: true })).not.toContainText('Loading earlier versions…')
  expect(reads.filter(path => path.endsWith('/entry_versions'))).toHaveLength(1)
  await openDetails(page, /^Your target & spending choices/)
  await expect.poll(() => reads.filter(path => path.endsWith('/plan_drafts')).length).toBe(1)
  expect(reads.filter(path => path === '/api/v1/savings_challenge')).toHaveLength(1)
})


test('BOG UI walkthrough saved-day shortcut and short Statements label fit phone targets', async ({ page }, info) => {
  await mockSavingsHome(page, true)
  await page.goto('/?pilot_e2e_role=participant#Home')
  const home = page.getByRole('region', { name: 'Savings challenge', exact: true })
  await expect(home.getByText('You checked in today')).toBeVisible()
  const statements = page.getByRole('navigation').getByRole('link', { name: 'Statements', exact: true })
  await page.evaluate(() => document.fonts.ready)
  const compact = statements.locator('.tabs-label-short')
  if (await compact.isVisible()) {
    await expect(compact).toHaveText('Statements')
    const fit = await compact.evaluate(node => ({ client: node.clientWidth, scroll: node.scrollWidth, columns: getComputedStyle(node.closest('nav')!).gridTemplateColumns }))
    expect(fit.scroll, JSON.stringify(fit)).toBeLessThanOrEqual(fit.client)
  }
  const box = await statements.boundingBox()
  expect(box!.width).toBeGreaterThanOrEqual(44)
  expect(box!.height).toBeGreaterThanOrEqual(44)
  if (process.env.HCFO_W3_EVIDENCE_DIR) await page.screenshot({ path: `${process.env.HCFO_W3_EVIDENCE_DIR}/shots/${info.project.name}-navigation-final.png` })
  await home.getByRole('button', { name: 'Open today’s saved items', exact: true }).click()
  const today = page.getByRole('dialog', { name: 'Today', exact: true })
  await expect(today).toBeVisible()
  await expect(today.getByRole('region', { name: 'Saved purchases', exact: true })).toContainText('Fictional lunch')
  await expect(today.getByRole('region', { name: 'Saved purchases', exact: true })).toContainText('$12.50')
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
})

test('BOG UI chat savings approval preserves its Saved notice and open entry panel when intake clears', async ({ page }) => {
  await mockSavingsHome(page)
  const actor = { user_id: 901, household_id: 1 }
  const challenge = { ...savingsFixture(), cohort_id: 1 }
  challenge.enrollment!.cohort_id = 1
  const draft = { id: 71, savings_entry_id: 31, lock_version: 0, status: 'pending', signed_cents: 2500, effective_on: '2026-10-04', funding_source: 'new_money_reserved', base_version_id: null, base_entry_lock_version: 0, reason: '' }
  let staged = false, approved = false
  await page.route('http://api.test/api/v1/savings_challenge/chat_cards', route => route.fulfill({ json: { records: staged ? [] : [{ id: 90, kind: 'savings', status: 'pending', lock_version: 0, enrollment_id: 1, message_id: 801, input: { kind: 'contribution', amount_cents: 2500, effective_on: '2026-10-04', counted: false, approval_state: 'unreviewed_input' }, state: {} }], actor_scope: actor, cohort_id: 1, enrollment_id: 1 } }))
  await page.route('http://api.test/api/v1/savings_challenge/entry_drafts**', async route => {
    const request = route.request()
    if (request.method() === 'POST') {
      if (request.url().endsWith('/approve')) approved = true
      else { expect(request.postDataJSON()).toMatchObject({ chat_card_id: 90 }); staged = true }
      return route.fulfill({ json: { record: approved ? { ...draft, status: 'approved' } : draft, challenge: { ...challenge, pending_entry_count: approved ? 0 : 1 }, replayed: false } })
    }
    return route.fulfill({ json: { records: staged && !approved ? [draft] : [], next_cursor: null, actor_scope: actor, cohort_id: 1, enrollment_id: 1 } })
  })
  await page.goto('/?pilot_e2e_role=participant#Ask%20Mia')
  // The chat card approves in place; Open in Savings is the way to the full entry form.
  await page.getByRole('button', { name: 'Open in Savings', exact: true }).click()
  const home = page.getByRole('region', { name: 'Savings challenge', exact: true })
  await expect(home.getByLabel('Amount in US dollars', { exact: true })).toHaveValue('25.00')
  await home.getByLabel(/This was new money/).check()
  await home.getByRole('button', { name: 'Review savings record', exact: true }).click()
  await home.getByRole('button', { name: 'Confirm $25.00 set aside on Sun, Oct 4' }).click()
  await expect(home).toContainText('Saved. Your total is up to date.')
  await expect(home.getByLabel('Amount in US dollars', { exact: true })).toBeVisible()
  await expect(home.getByLabel('Amount in US dollars', { exact: true })).toHaveValue('')
  expect(approved).toBe(true)
})


test('BOG UI shell savings Home last control and footer clear the floating bar', async ({ page }, info) => {
  test.skip(!['mobile-chrome', 'compact-mobile-chrome', 'mobile-webkit'].includes(info.project.name), 'phone clearance')
  await mockSavingsHome(page)
  await page.goto('/?pilot_e2e_role=participant#Home')
  await expect(page.getByRole('region', { name: 'Savings challenge', exact: true })).toBeVisible()
  await page.evaluate(() => document.fonts.ready)
  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight))
  const bounds = await page.evaluate(() => {
    const bar = document.querySelector('.tabs-shell')!.getBoundingClientRect()
    const footer = document.querySelector('.brand-footer')!.getBoundingClientRect()
    const controls = [...document.querySelectorAll<HTMLElement>('.shell-main :is(a[href], button, summary, input, select, textarea)')].filter(node => node.checkVisibility() && !node.closest('.brand-footer'))
    return { bar: bar.top, footer: footer.bottom, last: controls.at(-1)?.getBoundingClientRect().bottom }
  })
  expect(bounds.footer).toBeLessThanOrEqual(bounds.bar - 16)
  expect(bounds.last).toBeDefined()
  expect(bounds.last!).toBeLessThanOrEqual(bounds.bar - 16)
})


test('BOG UI shell savings identity names the program once', async ({ page }) => {
  await mockSavingsHome(page)
  await page.goto('/?pilot_e2e_role=participant#Home')
  const identity = page.locator('.shell-brand')
  await expect(identity.locator('h1')).toHaveText(workspace.workspace.cohort.name)
  await expect(identity.locator('.sidebar-scope')).toHaveCount(0)
})

test('BOG UI shell savings page ground covers mid-scroll text below the phone pill', async ({ page }, info) => {
  test.skip(!['mobile-chrome', 'compact-mobile-chrome', 'mobile-webkit'].includes(info.project.name), 'phone paint coverage')
  await mockSavingsHome(page)
  await page.goto('/?pilot_e2e_role=participant#Home')
  await expect(page.getByRole('article', { name: 'Approved savings progress', exact: true })).toBeVisible()
  await expectPhoneGroundCoverage(page)
})

test('BOG UI Today keeps the selected tab and content position during a background refresh', async ({ page }) => {
  await mockSavingsHome(page, true)
  await page.goto('/?pilot_e2e_role=participant#Home')
  await page.getByRole('button', { name: 'Open today’s saved items', exact: true }).click()
  const today = page.getByRole('dialog', { name: 'Today', exact: true })
  await today.getByRole('button', { name: 'Checkpoints', exact: true }).click()
  const heading = today.getByRole('heading', { name: 'Checkpoints', exact: true })
  await expect(heading).toBeVisible()
  await page.evaluate(() => document.fonts.ready)
  const before = await heading.boundingBox()
  let release!: () => void
  const held = new Promise<void>(resolve => { release = resolve })
  await page.route('http://api.test/api/v1/savings_challenge/daily', async route => {
    await held
    await route.fallback()
  })
  await page.evaluate(() => window.dispatchEvent(new Event('focus')))
  await expect(today.getByRole('status').filter({ hasText: 'Loading today…' })).toHaveCount(1)
  await expect(today.locator('.daily-loading')).toHaveCount(0)
  await expect(today.getByRole('button', { name: 'Checkpoints', exact: true })).toHaveAttribute('aria-pressed', 'true')
  const during = await heading.boundingBox()
  expect(Math.abs(during!.y - before!.y)).toBeLessThanOrEqual(1)
  release()
  await expect(today.locator('.daily-refreshing')).toHaveCount(0)
})
