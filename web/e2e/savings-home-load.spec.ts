import { expect, test, type Page } from '@playwright/test'
import workspace from './fixtures/savings-home-workspace.json' with { type: 'json' }
import { savingsFixture, savingsPlanVersion } from '../src/test/savingsFixtures'
import { dailyContext } from '../src/test/dailyFixtures'

// Synthetic Rails workspace captured from an isolated, system-sealed savings cohort.
// Every endpoint remains observable; no private read is silently supplied by a cache.
async function mockSavingsHome(page: Page, checkedIn = false) {
  const challenge = { ...savingsFixture(), cohort_id: 1, accepted_plan: savingsPlanVersion() }
  challenge.enrollment!.cohort_id = 1
  challenge.enrollment!.current_accepted_plan_version_id = 21
  const actor = { user_id: 901, household_id: 1 }
  await page.route('http://api.test/api/**', route => {
    const path = new URL(route.request().url()).pathname
    if (path === '/api/public/brand') return route.fulfill({ json: { brand: workspace.workspace.brand.config, available: true, source: 'legacy_household_cfo_default', workspace: null, version: null, primary_domain: '127.0.0.1' } })
    if (path === '/api/v1/auth/me') return route.fulfill({ json: { user: { id: 901, clerk_id: 'e2e_participant', email: 'participant@pilot.test', first_name: 'Test', last_name: 'Participant', full_name: 'Test Participant', role: 'participant', is_participant: true, is_staff: false, is_admin: false, is_coach: false, invitation_status: 'accepted', coach_workspaces: [], active_coach_workspace: null } } })
    if (path === '/api/v1/workspace') return route.fulfill({ json: workspace })
    if (path === '/api/v1/savings_challenge') return route.fulfill({ json: challenge })
    if (path === '/api/v1/savings_challenge/daily') return route.fulfill({ json: { ...dailyContext, day: { ...dailyContext.day, local_on: challenge.calendar!.local_today, check_in_id: checkedIn ? 7 : null, check_in_version_id: checkedIn ? 8 : null, spending_state: checkedIn ? 'no_spend' : 'unknown', completed_at: checkedIn ? '2026-10-04T01:00:00Z' : null }, actor_scope: actor, cohort_id: 1, enrollment_id: 1, calendar: challenge.calendar } })
    if (/\/savings_challenge\/(entry_drafts|entries|plan_drafts|entry_versions)$/.test(path)) return route.fulfill({ json: { actor_scope: actor, cohort_id: 1, enrollment_id: 1, records: [], next_cursor: null } })
    return route.fulfill({ status: 404, json: { errors: ['Unexpected fixture read'] } })
  })
}

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
  expect(reads.filter(path => path.startsWith('/api/v1/savings_challenge'))).toEqual(['/api/v1/savings_challenge', '/api/v1/savings_challenge/daily'])
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


test('BOG UI walkthrough saved-day shortcut and short Statements label fit phone targets', async ({ page }) => {
  await mockSavingsHome(page, true)
  await page.goto('/?pilot_e2e_role=participant#Home')
  const home = page.getByRole('region', { name: 'Savings challenge', exact: true })
  await expect(home.getByText('You checked in today')).toBeVisible()
  const statements = page.getByRole('navigation').getByRole('link', { name: 'Statements', exact: true })
  const compact = statements.locator('.tabs-label-short')
  if (await compact.isVisible()) {
    await expect(compact).toHaveText('Files')
    expect(await compact.evaluate(node => node.scrollWidth <= node.clientWidth)).toBe(true)
  }
  const box = await statements.boundingBox()
  expect(box!.width).toBeGreaterThanOrEqual(44)
  expect(box!.height).toBeGreaterThanOrEqual(44)
  await home.getByRole('button', { name: 'Open today’s saved items', exact: true }).click()
  await expect(page.getByRole('dialog', { name: 'Today', exact: true })).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
})
