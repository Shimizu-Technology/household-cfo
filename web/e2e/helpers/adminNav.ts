import { TEXT_ENTRY_SELECTOR } from '../../src/lib/textEntry'
import { expect, type Page } from '@playwright/test'

// The Admin side's own navigation, shared by the live specs that walk through Coaching, History and Settings.

export const coachingUrl = (web: string, role: 'admin' | 'coach') => `${web}/admin/coaching?pilot_e2e_role=${role}&pilot_e2e_live_api=true`

/** Opens a section from the sidebar on a wide screen, or from the floating tabs and More on a phone. */
export async function openAdminSection(page: Page, name: 'Today' | 'People' | 'Groups' | 'Coaching' | 'Reports' | 'Support' | 'Settings') {
  const label = new RegExp(`^${name}`)
  const sidebar = page.getByRole('navigation', { name: 'Admin', exact: true })
  if (await sidebar.isVisible()) await sidebar.getByRole('link', { name: label }).click()
  else {
    if ((page.viewportSize()?.width ?? 0) <= 620) await page.evaluate(selector => { const active = document.activeElement; if (active instanceof HTMLElement && active.matches(selector)) active.blur() }, TEXT_ENTRY_SELECTOR)
    const primary = page.getByRole('navigation', { name: 'Admin sections', exact: true }).getByRole('link', { name: label })
    if (await primary.count()) await primary.click()
    else { await page.getByRole('button', { name: 'More', exact: true }).click(); await page.getByRole('dialog', { name: 'More', exact: true }).getByRole('link', { name: label }).click() }
  }
  await expect(page.locator('.admin-content [data-page-heading]').first()).toHaveText(name)
}

/** The voice and live destinations in the three-step Coaching navigation. */
export function coachingStep(page: Page, step: 'voice' | 'live') {
  return page.getByRole('navigation', { name: 'Coaching steps' }).getByRole('button', { name: step === 'voice' ? /^1 · Your coach/ : /^3 · Preview and go live/ })
}

/** Settings → Name and look: the program name, coach profile and the app's own look. */
export async function openProgramLook(page: Page) {
  await openAdminSection(page, 'Settings')
  await page.locator('summary', { hasText: 'Name and look' }).click()
}
