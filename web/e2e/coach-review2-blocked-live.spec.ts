import { test, expect } from '@playwright/test'
import { mkdir } from 'node:fs/promises'
const live = process.env.HCFO_W16_WEB
const workspace = process.env.HCFO_W16_BLOCKED_WORKSPACE
const evidence = process.env.HCFO_W16_EVIDENCE

test('Coach Studio names an accepted participant sign-in blocker before approval without phone overflow', async ({ page }, info) => {
  test.skip(!live || !workspace, 'Requires isolated W16 accepted-but-unlinked fixture')
  test.setTimeout(120_000)
  if (info.project.name === 'desktop-chrome') await page.setViewportSize({ width: 1366, height: 900 })
  await page.goto(`${live}/admin/coaching?pilot_e2e_role=admin&pilot_e2e_live_api=true`)
  await page.getByLabel('Program', { exact: true }).selectOption(workspace!)
  await page.getByRole('navigation', { name: 'Coaching steps' }).getByRole('button', { name: /^2 · Preview and go live/ }).click()
  await expect(page.getByRole('alert').filter({ hasText: 'Maria Santos del Rosario Household Participant needs to finish setting up their sign-in' })).toBeVisible({ timeout: 60_000 })
  await expect(page.getByRole('button', { name: 'Approve and go live', exact: true })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Review changes', exact: true })).toBeEnabled()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
  if (evidence) {
    await mkdir(evidence, { recursive: true })
    await page.screenshot({ path: `${evidence}/${info.project.name}-blocked-review.png`, fullPage: true, scale: 'css' })
  }
})
