import { expect, type Page } from '@playwright/test'

// The Admin side's own navigation, shared by the live specs that walk through Coaching, History and Settings.

export const coachingUrl = (web: string, role: 'admin' | 'coach') => `${web}/admin/coaching?pilot_e2e_role=${role}&pilot_e2e_live_api=true`

/** Opens a section from the sidebar on a wide screen, or from the section menu on a phone. */
export async function openAdminSection(page: Page, name: 'Today' | 'People' | 'Groups' | 'Coaching' | 'Reports' | 'Support' | 'Settings') {
  const label = new RegExp(`^${name}`)
  const menu = page.locator('details.admin-section-menu')
  if (await menu.isVisible()) {
    await menu.locator('summary').click()
    await menu.getByRole('link', { name: label }).click()
  } else {
    await page.getByRole('navigation', { name: 'Admin', exact: true }).getByRole('link', { name: label }).click()
  }
  await expect(page.locator('.admin-content [data-page-heading]').first()).toHaveText(name)
}

/** The two Coaching steps: "1 · Your coach’s voice" and "2 · Preview and go live". */
export function coachingStep(page: Page, step: 'voice' | 'live') {
  return page.getByRole('navigation', { name: 'Coaching steps' }).getByRole('button', { name: step === 'voice' ? /^1 · Your coach/ : /^2 · Preview and go live/ })
}

/** Settings → Name and look: the program name, coach profile and the app's own look. */
export async function openProgramLook(page: Page) {
  await openAdminSection(page, 'Settings')
  await page.locator('summary', { hasText: 'Name and look' }).click()
}
